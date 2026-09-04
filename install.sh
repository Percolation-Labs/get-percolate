#!/bin/sh
# Install the Percolate extensions into a PostgreSQL 19 you already run.
#
#   curl -fsSL https://raw.githubusercontent.com/Percolation-Labs/get-percolate/main/install.sh | sh
#   PG_CONFIG=/usr/lib/postgresql/19/bin/pg_config sh install.sh
#   VERSION=v0.1.0 sh install.sh
#
# Two extensions, and they ship differently because they ARE different:
#
#   percolate         pure SQL, one file, architecture-independent
#   percolate_parser  a Rust .so, and a shared library has to be built for a
#                     specific (postgres major, os, arch) triple -- there is no
#                     portable form of it, so we prebuild the common ones
#
# This script never builds anything. If there is no prebuilt parser for your
# platform it installs the SQL extension, says so, and exits non-zero -- rather
# than reporting success for a half install whose failure would first appear as
# `function p8_compile_workflow does not exist` at the point someone tries to
# define their first workflow.
set -eu

REPO="${REPO:-Percolation-Labs/get-percolate}"
VERSION="${VERSION:-latest}"

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- pg_config
# pg_config is the only thing that knows where THIS postgres keeps its
# extensions -- guessing /usr/share/postgresql/19 is right on Debian and wrong
# on Homebrew, RedHat, Postgres.app and every container that moved it.
PG_CONFIG="${PG_CONFIG:-$(command -v pg_config || true)}"
[ -n "$PG_CONFIG" ] || die "pg_config not found. Install the postgres dev package
  (Debian/Ubuntu: apt install postgresql-server-dev-19)
  or point at it: PG_CONFIG=/path/to/pg_config sh install.sh"

PG_MAJOR=$("$PG_CONFIG" --version | sed -n 's/^PostgreSQL \([0-9][0-9]*\).*/\1/p')
[ "$PG_MAJOR" = "19" ] || die "this build targets PostgreSQL 19, found ${PG_MAJOR:-unknown}.
  SQL/PGQ property graphs are a PG19 feature and the parser is compiled against
  its ABI -- neither degrades gracefully on 18."

SHAREDIR=$("$PG_CONFIG" --sharedir)/extension
PKGLIBDIR=$("$PG_CONFIG" --pkglibdir)

# ---------------------------------------------------------------- platform
os=$(uname -s); arch=$(uname -m)
case "$os:$arch" in
  Linux:x86_64|Linux:amd64)   PLATFORM=linux-amd64 ;;
  Linux:aarch64|Linux:arm64)  PLATFORM=linux-arm64 ;;
  Darwin:arm64)               PLATFORM=macos-arm64 ;;
  *)                          PLATFORM="" ;;
esac

if [ "$VERSION" = latest ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Returns nonzero instead of exiting, for the things that have a fallback.
# `fetch` below dies, which is right for the extension itself and wrong for
# anything optional -- an early version used `fetch ... || fetch ...` and the
# first call exited the script before the second could run.
try_fetch() { curl -fsSL "$1" -o "$2" 2>/dev/null; }

fetch() {
  curl -fsSL "$1" -o "$2" 2>/dev/null \
    || die "could not download $1
  Check https://github.com/$REPO/releases for a published release. If you are
  running ahead of one, the Docker image carries the same extensions:
  percolationlabs/percolate-postgres:19"
}

# ---------------------------------------------------------------- percolate
# The version is READ, not hardcoded. A control file names the script Postgres
# will run -- `default_version = 0.2.0` means `percolate--0.2.0.sql` -- so
# downloading the control file first and asking it what it wants is the only
# way this script keeps working across a release. It used to name
# percolate--0.1.0.sql literally, which made every future version a silent
# 404 in a curl | sh.
control_version() {
  sed -n "s/^default_version = '\\(.*\\)'/\\1/p" "$1" | head -1
}

say "==> percolate (SQL) -> $SHAREDIR"
fetch "$BASE/percolate.control" "$TMP/percolate.control"
PV=$(control_version "$TMP/percolate.control")
[ -n "$PV" ] || die "percolate.control has no default_version -- the release is malformed"
say "    version $PV"
fetch "$BASE/percolate--$PV.sql" "$TMP/percolate--$PV.sql"

# install(1) rather than cp, so a non-writable sharedir fails HERE with a
# readable message instead of half-copying and leaving a control file pointing
# at a script that is not there.
install -m 644 "$TMP/percolate.control" "$TMP/percolate--$PV.sql" "$SHAREDIR/" \
  || die "cannot write to $SHAREDIR -- rerun with sudo, or as the postgres owner"

# ------------------------------------------------------- percolate_parser
if [ -z "$PLATFORM" ]; then
  say ""
  say "!! No prebuilt parser for $os/$arch."
  say "   percolate is installed and every SQL capability works. The P8QL and"
  say "   YAML compilers do NOT: define_yaml() and p8ql: steps will fail until"
  say "   percolate_parser is built for this platform."
  say ""
  say "   The Docker image carries a prebuilt parser for linux/amd64 and"
  say "   linux/arm64: percolationlabs/percolate-postgres:19"
  say "   For another platform, open an issue at github.com/$REPO/issues with"
  say "   the output of \\`uname -sm\\` and it can be added to the build matrix."
  exit 3
fi

say "==> percolate_parser ($PLATFORM) -> $PKGLIBDIR"
fetch "$BASE/percolate_parser.control" "$TMP/percolate_parser.control"
QV=$(control_version "$TMP/percolate_parser.control")
[ -n "$QV" ] || die "percolate_parser.control has no default_version -- the release is malformed"
# The two extensions are released as one number. If a release ever carries two,
# `CREATE EXTENSION percolate CASCADE` would resolve a parser the schema was
# not built against -- worth one line to refuse rather than discover later.
[ "$QV" = "$PV" ] || die "this release is inconsistent: percolate $PV, percolate_parser $QV.
  Report it at https://github.com/$REPO/issues -- do not install it."
fetch "$BASE/percolate_parser-$PLATFORM.so" "$TMP/percolate_parser.so"
fetch "$BASE/percolate_parser--$QV.sql"     "$TMP/percolate_parser--$QV.sql"

install -m 755 "$TMP/percolate_parser.so" "$PKGLIBDIR/" \
  || die "cannot write to $PKGLIBDIR -- rerun with sudo"
install -m 644 "$TMP/percolate_parser.control" "$TMP/percolate_parser--$QV.sql" "$SHAREDIR/"

# ------------------------------------------------------- bootstrap.sql
# Fetched, not just mentioned. `CREATE EXTENSION percolate` on its own cannot
# work whoever runs it -- as a superuser the extension refuses to load, and as
# anybody else the roles it needs do not exist yet -- so telling someone to run
# it is telling them to hit an error. This script used to end by doing exactly
# that.
# The release first, then main -- bootstrap.sql does not name a version, so
# either is correct, and preferring the release keeps a pinned install
# self-consistent.
if ! try_fetch "$BASE/bootstrap.sql" ./bootstrap.sql &&
   ! try_fetch "https://raw.githubusercontent.com/$REPO/main/bootstrap.sql" ./bootstrap.sql
then
  say ""
  say "!! Could not download bootstrap.sql. The extension files are installed,"
  say "   but the database still needs the roles it creates. Get it from"
  say "   https://github.com/$REPO/blob/main/bootstrap.sql"
  exit 4
fi

say ""
say "Installed. The files are in place; the database does not have them yet."
say ""
say "Run ./bootstrap.sql (downloaded here) as a SUPERUSER, against the database"
say "that will hold it:"
say ""
say "  psql -d yourdb -v ON_ERROR_STOP=1 \\"
say "       -v auth_pw=\"\$(openssl rand -base64 24)\" \\"
say "       -v worker_pw=\"\$(openssl rand -base64 24)\" \\"
say "       -f bootstrap.sql"
say ""
say "It creates the cluster roles, installs vector and percolate_parser, and then"
say "installs percolate AS app_owner. That last part is why a bare"
say "\`CREATE EXTENSION percolate CASCADE\` is not enough: the extension REFUSES to"
say "load as a superuser, because a superuser owner bypasses row-level security"
say "unconditionally and would leave every policy in the collection inert while"
say "looking correct. Creating a role needs a superuser; owning the schema must"
say "not be one, so the two are separate steps."
say ""
say "Verify: select * from workflow.compiler_capabilities();"
say ""
say "Then make the first administrator. rbac ships EMPTY -- the alternative is a"
say "default account with a known password -- and until a role is granted to"
say "somebody, every *_api view returns no rows to anyone, which looks exactly"
say "like an install that did not work rather than like one nobody has logged"
say "into yet:"
say ""
say "  select rbac.bootstrap_admin('you@example.com', 'a long passphrase');"
