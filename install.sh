#!/bin/sh
# Install the Percolate extensions into a PostgreSQL 19 you already run.
#
#   curl -fsSL https://raw.githubusercontent.com/percolating-sirsh/get-percolate/main/install.sh | sh
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

REPO="${REPO:-percolating-sirsh/get-percolate}"
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
fetch() {
  curl -fsSL "$1" -o "$2" 2>/dev/null \
    || die "could not download $1
  Check https://github.com/$REPO/releases for a published release. If you are
  running ahead of one, the Docker image carries the same extensions:
  percolationlabs/percolate-postgres:19"
}

# ---------------------------------------------------------------- percolate
say "==> percolate (SQL) -> $SHAREDIR"
fetch "$BASE/percolate.control"        "$TMP/percolate.control"
fetch "$BASE/percolate--0.1.0.sql"     "$TMP/percolate--0.1.0.sql"

# install(1) rather than cp, so a non-writable sharedir fails HERE with a
# readable message instead of half-copying and leaving a control file pointing
# at a script that is not there.
install -m 644 "$TMP/percolate.control" "$TMP/percolate--0.1.0.sql" "$SHAREDIR/" \
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
fetch "$BASE/percolate_parser-$PLATFORM.so"    "$TMP/percolate_parser.so"
fetch "$BASE/percolate_parser.control"         "$TMP/percolate_parser.control"
fetch "$BASE/percolate_parser--0.1.0.sql"      "$TMP/percolate_parser--0.1.0.sql"

install -m 755 "$TMP/percolate_parser.so" "$PKGLIBDIR/" \
  || die "cannot write to $PKGLIBDIR -- rerun with sudo"
install -m 644 "$TMP/percolate_parser.control" "$TMP/percolate_parser--0.1.0.sql" "$SHAREDIR/"

say ""
say "Installed. Now, in the database that will hold it:"
say ""
say "  CREATE EXTENSION IF NOT EXISTS vector;          -- prerequisite, packaged everywhere"
say "  CREATE EXTENSION percolate CASCADE;             -- pulls in percolate_parser"
say ""
say "CASCADE matters: percolate depends on percolate_parser, pgcrypto and pg_trgm,"
say "and none of them is a trusted extension, so the CREATE must be superuser."
say "Everything percolate itself creates is owned by a non-superuser on purpose --"
say "a superuser bypasses row-level security unconditionally, which would leave"
say "every policy in the schema inert."
say ""
say "Verify: select * from workflow.compiler_capabilities();"
