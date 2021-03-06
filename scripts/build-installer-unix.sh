#!/bin/sh
# DEPENDENCIES (binaries should be in PATH):
#   0. 'git'
#   1. 'curl'
#   2. 'nix-shell'
#   3. 'stack'

set -e

usage() {
    test -z "$1" || { echo "ERROR: $*" >&2; echo >&2; }
    cat >&2 <<EOF
  Usage:
    $0 DAEDALUS-VERSION CARDANO-BRANCH OPTIONS*

  Build a Daedalus installer.

  Options:
    --fast-impure             Fast, impure, incremental build
    --build-id BUILD-NO       Identifier of the build; defaults to '0'

    --travis-pr PR-ID         Travis pull request id we're building
    --nix-path NIX-PATH       NIX_PATH value

    --upload-s3               Upload the installer to S3
    --test-install            Test the installer for installability

    --verbose                 Verbose operation
    --quiet                   Disable verbose operation
    
EOF
    test -z "$1" || exit 1
}
alias   argnz='test $# -ge 1 -a ! -z "$1" || usage "empty value for"'
alias  arg2nz='test $# -ge 2 -a ! -z "$2" || usage "empty value for"'
alias  argnzf='test $# -ge 1 -a ! -z "$1" || fail "missing value for"'
alias arg2nzf='test $# -ge 2 -a ! -z "$2" || fail "missing value for"'
fail() { echo "ERROR: $*" >&2; exit 1;
}
retry() {
        local tries=$1; argnzf "iteration count"; shift
        for i in $(seq 1 ${tries})
        do if "$@"
           then return 0
           fi
           sleep 5s
        done
        fail "persistent failure to exec:  $*"
}

###
### Argument processing
###
fast_impure=
verbose=true
build_id=0
travis_pr=true
upload_s3=
test_install=

daedalus_version="$1"; argnz "product version"; shift
cardano_branch="$1";   argnz "Cardano SL branch to build Daedalus with"; shift

case "$(uname -s)" in
        Darwin ) os=osx;   key=macos.p12;;
        Linux )  os=linux; key=linux.p12;;
        * )     usage "Unsupported OS: $(uname -s)";;
esac

set -u ## Undefined variable firewall enabled
while test $# -ge 1
do case "$1" in
           --fast-impure )                               fast_impure=true;;
           --build-id )       arg2nz "build identifier";    build_id="$2"; shift;;
           --travis-pr )      arg2nz "Travis pull request id";
                                                           travis_pr="$2"; shift;;
           --nix-path )       arg2nz "NIX_PATH value";
                                                     export NIX_PATH="$2"; shift;;
           --upload-s3 )                                   upload_s3=t;;
           --test-install )                             test_install=t;;

           ###
           --verbose )        echo "$0: --verbose passed, enabling verbose operation"
                                                             verbose=t;;
           --quiet )          echo "$0: --quiet passed, disabling verbose operation"
                                                             verbose=;;
           --help )           usage;;
           "--"* )            usage "unknown option: '$1'";;
           * )                break;; esac
   shift; done

set -e
if test -n "${verbose}"
then set -x
fi

mkdir -p ~/.local/bin

export PATH=$HOME/.local/bin:$PATH
export DAEDALUS_VERSION=${daedalus_version}.${build_id}
export SSL_CERT_FILE=$NIX_SSL_CERT_FILE

test -d node_modules/daedalus-client-api/ -a -n "${fast_impure}" || {
        retry 5 curl -o daedalus-bridge.tar.xz \
              https://s3.eu-central-1.amazonaws.com/cardano-sl-travis/daedalus-bridge-${os}-${cardano_branch}.tar.xz
        mkdir -p node_modules/daedalus-client-api/
        du -sh  daedalus-bridge.tar.xz
        tar xJf daedalus-bridge.tar.xz --strip-components=1 -C node_modules/daedalus-client-api/
        rm      daedalus-bridge.tar.xz
        cd node_modules/daedalus-client-api
              mv log-config-prod.yaml cardano-node cardano-launcher ../../installers
        cd ../..
        strip installers/cardano-node installers/cardano-launcher
        rm -f node_modules/daedalus-client-api/cardano-*
}
echo "cardano-sl build id is $(cat node_modules/daedalus-client-api/build-id)"

test $(ls node_modules/ | wc -l) -gt 100 -a -n "${fast_impure}" ||
        nix-shell --run "npm install"

test -d "release/darwin-x64/Daedalus-darwin-x64" -a -n "${fast_impure}" || {
        nix-shell --run "npm run package -- --icon installers/icons/256x256"
        echo "Size of Electron app is $(du -sh release)"
}

test -n "$(which stack)"     -a -n "${fast_impure}" ||
        retry 5 bash -c "curl -L https://www.stackage.org/stack/${os}-x86_64 | \
                         tar xz --strip-components=1 -C ~/.local/bin"

cd installers
    if test "${travis_pr}" = "false" -a "${os}" != "linux" # No Linux keys yet.
    then retry 5 nix-shell -p awscli --run "aws s3 cp --region eu-central-1 s3://iohk-private/${key} ${key}"
    fi
    stack --no-terminal --nix build --exec make-installer --jobs 2
    mkdir -p dist
    if test -n "${upload_s3}"
    then
            echo "$0: --upload-s3 passed, will upload the installer to S3";
            retry 5 nix-shell -p awscli --run "aws s3 cp 'dist/Daedalus-installer-${DAEDALUS_VERSION}.pkg' s3://daedalus-internal/ --acl public-read"
    fi
    if test -n "${test_install}"
    then echo "$0:  --test-install passed, will test the installer for installability";
         case ${os} in
                 osx )   sudo installer -dumplog -verbose -pkg "dist/Daedalus-installer-${DAEDALUS_VERSION}.pkg" -target /;;
                 linux ) echo "WARNING: installation testing not implemented on Linux" >&2;; esac; fi
cd ..

ls -la installers/dist

exit 0
