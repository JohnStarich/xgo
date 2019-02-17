#!/bin/bash
#
# Contains the main cross compiler, that individually sets up each target build
# platform, compiles all the C dependencies, then build the requested executable
# itself.
#
# Usage: build.sh <import path>
#
# Needed environment variables:
#   REPO_REMOTE    - Optional VCS remote if not the primary repository is needed
#   REPO_BRANCH    - Optional VCS branch to use, if not the master branch
#   DEPS           - Optional list of C dependency packages to build
#   ARGS           - Optional arguments to pass to C dependency configure scripts
#   PACK           - Optional sub-package, if not the import path is being built
#   OUT            - Optional output prefix to override the package name
#   FLAG_V         - Optional verbosity flag to set on the Go builder
#   FLAG_X         - Optional flag to print the build progress commands
#   FLAG_RACE      - Optional race flag to set on the Go builder
#   FLAG_TAGS      - Optional tag flag to set on the Go builder
#   FLAG_LDFLAGS   - Optional ldflags flag to set on the Go builder
#   FLAG_BUILDMODE - Optional buildmode flag to set on the Go builder
#   TARGETS        - Comma separated list of build targets to compile for
#   GO_VERSION     - Bootstrapped version of Go to disable uncupported targets
#   EXT_GOPATH     - GOPATH elements mounted from the host filesystem

# Define a function that figures out the binary extension
function extension {
  if [ "$1" == "windows" ]; then
    echo 'Windows is unsupported in xgo-base:nano' >&2
    exit 2
  fi
  if [ "$FLAG_BUILDMODE" == "archive" ] || [ "$FLAG_BUILDMODE" == "c-archive" ]; then
    echo ".a"
  elif [ "$FLAG_BUILDMODE" == "shared" ] || [ "$FLAG_BUILDMODE" == "c-shared" ]; then
    if [ "$1" == "darwin" ] || [ "$1" == "ios" ]; then
      echo ".dylib"
    else
      echo ".so"
    fi
  fi
}

# Detect if we are using go modules
if [[ "$GO111MODULE" == "on" || "$GO111MODULE" == "auto" ]]; then
  USEMODULES=true
  else
  USEMODULES=false
fi

# Either set a local build environemnt, or pull any remote imports
if [ "$EXT_GOPATH" != "" ]; then
  # If local builds are requested, inject the sources
  echo "Building locally $1..."
  export GOPATH=$GOPATH:$EXT_GOPATH
  set -e

  # Find and change into the package folder
  cd `go list -e -f {{.Dir}} $1`
  export GOPATH=$GOPATH:`pwd`/Godeps/_workspace
elif [[ "$USEMODULES" == true ]]; then
  # Go module builds should assume a local repository
  # at mapped to /source containing at least a go.mod file.
  if [[ ! -d /source ]]; then
    echo "Go modules are enabled but go.mod was not found in the source folder."
    exit 10
  fi
  # Change into the repo/source folder
  cd /source
  echo "Building /source/go.mod..."
else
  # Inject all possible Godep paths to short circuit go gets
  GOPATH_ROOT=$GOPATH/src
  IMPORT_PATH=$1
  while [ "$IMPORT_PATH" != "." ]; do
    export GOPATH=$GOPATH:$GOPATH_ROOT/$IMPORT_PATH/Godeps/_workspace
    IMPORT_PATH=`dirname $IMPORT_PATH`
  done

  # Otherwise download the canonical import path (may fail, don't allow failures beyond)
  echo "Fetching main repository $1..."
  go get -v -d $1
  set -e

  cd $GOPATH_ROOT/$1

  # Switch over the code-base to another checkout if requested
  if [ "$REPO_REMOTE" != "" ] || [ "$REPO_BRANCH" != "" ]; then
    # Detect the version control system type
    IMPORT_PATH=$1
    while [ "$IMPORT_PATH" != "." ] && [ "$REPO_TYPE" == "" ]; do
      if [ -d "$GOPATH_ROOT/$IMPORT_PATH/.git" ]; then
        REPO_TYPE="git"
      elif  [ -d "$GOPATH_ROOT/$IMPORT_PATH/.hg" ]; then
        REPO_TYPE="hg"
      fi
      IMPORT_PATH=`dirname $IMPORT_PATH`
    done

    if [ "$REPO_TYPE" == "" ]; then
      echo "Unknown version control system type, cannot switch remotes and branches."
      exit -1
    fi
    # If we have a valid VCS, execute the switch operations
    if [ "$REPO_REMOTE" != "" ]; then
      echo "Switching over to remote $REPO_REMOTE..."
      if [ "$REPO_TYPE" == "git" ]; then
        git remote set-url origin $REPO_REMOTE
        git fetch --all
        git reset --hard origin/HEAD
        git clean -dxf
      elif [ "$REPO_TYPE" == "hg" ]; then
        echo -e "[paths]\ndefault = $REPO_REMOTE\n" >> .hg/hgrc
        hg pull
      fi
    fi
    if [ "$REPO_BRANCH" != "" ]; then
      echo "Switching over to branch $REPO_BRANCH..."
      if [ "$REPO_TYPE" == "git" ]; then
        git reset --hard origin/$REPO_BRANCH
        git clean -dxf
      elif [ "$REPO_TYPE" == "hg" ]; then
        hg checkout $REPO_BRANCH
      fi
    fi
  fi
fi

# Download all the C dependencies
mkdir /deps
DEPS=($DEPS) && for dep in "${DEPS[@]}"; do
  if [ "${dep##*.}" == "tar" ]; then cat "/deps-cache/`basename $dep`" | tar -C /deps -x; fi
  if [ "${dep##*.}" == "gz" ];  then cat "/deps-cache/`basename $dep`" | tar -C /deps -xz; fi
  if [ "${dep##*.}" == "bz2" ]; then cat "/deps-cache/`basename $dep`" | tar -C /deps -xj; fi
done

DEPS_ARGS=($ARGS)

# Save the contents of the pre-build /usr/local folder for post cleanup
USR_LOCAL_CONTENTS=`ls /usr/local`

# Configure some global build parameters
NAME=`basename $1/$PACK`

# Go module-based builds error with 'cannot find main module'
# when $PACK is defined
if [[ "$USEMODULES" = true ]]; then
  PACK_RELPATH=""
  NAME=`sed -n 's/module\ \(.*\)/\1/p' /source/go.mod`
else
  PACK_RELPATH="./$PACK"
fi

if [ "$OUT" != "" ]; then
  NAME=$OUT
fi

if [ "$FLAG_V" == "true" ];    then V=-v; fi
if [ "$FLAG_X" == "true" ];    then X=-x; fi
if [ "$FLAG_RACE" == "true" ]; then R=-race; fi
if [ "$FLAG_TAGS" != "" ];     then T=(--tags "$FLAG_TAGS"); fi
if [ "$FLAG_LDFLAGS" != "" ];  then LD="$FLAG_LDFLAGS"; fi

if [ "$FLAG_BUILDMODE" != "" ] && [ "$FLAG_BUILDMODE" != "default" ]; then BM="--buildmode=$FLAG_BUILDMODE"; fi
if [ "$FLAG_MOD" != "" ]; then MOD="--mod=$FLAG_MOD"; fi

# If no build targets were specified, inject a catch all wildcard
if [ "$TARGETS" == "" ]; then
  TARGETS="./."
fi

# Build for each requested platform individually
for TARGET in $TARGETS; do
  # Split the target into platform and architecture
  XGOOS=`echo $TARGET | cut -d '/' -f 1`
  XGOARCH=`echo $TARGET | cut -d '/' -f 2`

  # Check and build for Android targets
  if ([ $XGOOS == "." ] || [[ $XGOOS == android* ]]); then
    echo 'Android is unsupported in xgo-base:nano' >&2
    exit 2
  fi
  # Check and build for Linux targets
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "amd64" ]); then
    echo "Compiling for linux/amd64..."
    HOST=x86_64-linux PREFIX=/usr/local $BUILD_DEPS /deps ${DEPS_ARGS[@]}
    if [[ "$USEMODULES" == false ]]; then
      GOOS=linux GOARCH=amd64 CGO_ENABLED=1 go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
    fi
    GOOS=linux GOARCH=amd64 CGO_ENABLED=1 go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $R $BM -o "/build/$NAME-linux-amd64$R`extension linux`" $PACK_RELPATH
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "386" ]); then
    echo "Compiling for linux/386..."
    HOST=i686-linux PREFIX=/usr/local $BUILD_DEPS /deps ${DEPS_ARGS[@]}
    if [[ "$USEMODULES" == false ]]; then
      GOOS=linux GOARCH=386 CGO_ENABLED=1 go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
    fi
    GOOS=linux GOARCH=386 CGO_ENABLED=1 go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $BM -o "/build/$NAME-linux-386`extension linux`" $PACK_RELPATH
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "arm" ] || [ $XGOARCH == "arm-5" ]); then
    if [ "$GO_VERSION" -ge 150 ]; then
      echo "Bootstrapping linux/arm-5..."
      CC=arm-linux-gnueabi-gcc-5 GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=1 CGO_CFLAGS="-march=armv5" CGO_CXXFLAGS="-march=armv5" go install std
    fi
    echo "Compiling for linux/arm-5..."
    CC=arm-linux-gnueabi-gcc-5 CXX=arm-linux-gnueabi-g++-5 HOST=arm-linux-gnueabi PREFIX=/usr/arm-linux-gnueabi CFLAGS="-march=armv5" CXXFLAGS="-march=armv5" $BUILD_DEPS /deps ${DEPS_ARGS[@]}
    export PKG_CONFIG_PATH=/usr/arm-linux-gnueabi/lib/pkgconfig

    if [[ "$USEMODULES" == false ]]; then
      CC=arm-linux-gnueabi-gcc-5 CXX=arm-linux-gnueabi-g++-5 GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=1 CGO_CFLAGS="-march=armv5" CGO_CXXFLAGS="-march=armv5" go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
    fi
    CC=arm-linux-gnueabi-gcc-5 CXX=arm-linux-gnueabi-g++-5 GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=1 CGO_CFLAGS="-march=armv5" CGO_CXXFLAGS="-march=armv5" go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $BM -o "/build/$NAME-linux-arm-5`extension linux`" $PACK_RELPATH
    if [ "$GO_VERSION" -ge 150 ]; then
      echo "Cleaning up Go runtime for linux/arm-5..."
      rm -rf /usr/local/go/pkg/linux_arm
    fi
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "arm-6" ]); then
    if [ "$GO_VERSION" -lt 150 ]; then
      echo "Go version too low, skipping linux/arm-6..."
    else
      echo "Bootstrapping linux/arm-6..."
      CC=arm-linux-gnueabi-gcc-5 GOOS=linux GOARCH=arm GOARM=6 CGO_ENABLED=1 CGO_CFLAGS="-march=armv6" CGO_CXXFLAGS="-march=armv6" go install std

      echo "Compiling for linux/arm-6..."
      CC=arm-linux-gnueabi-gcc-5 CXX=arm-linux-gnueabi-g++-5 HOST=arm-linux-gnueabi PREFIX=/usr/arm-linux-gnueabi CFLAGS="-march=armv6" CXXFLAGS="-march=armv6" $BUILD_DEPS /deps ${DEPS_ARGS[@]}
      export PKG_CONFIG_PATH=/usr/arm-linux-gnueabi/lib/pkgconfig

      if [[ "$USEMODULES" == false ]]; then
        CC=arm-linux-gnueabi-gcc-5 CXX=arm-linux-gnueabi-g++-5 GOOS=linux GOARCH=arm GOARM=6 CGO_ENABLED=1 CGO_CFLAGS="-march=armv6" CGO_CXXFLAGS="-march=armv6" go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
      fi
      CC=arm-linux-gnueabi-gcc-5 CXX=arm-linux-gnueabi-g++-5 GOOS=linux GOARCH=arm GOARM=6 CGO_ENABLED=1 CGO_CFLAGS="-march=armv6" CGO_CXXFLAGS="-march=armv6" go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $BM -o "/build/$NAME-linux-arm-6`extension linux`" $PACK_RELPATH

      echo "Cleaning up Go runtime for linux/arm-6..."
      rm -rf /usr/local/go/pkg/linux_arm
    fi
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "arm-7" ]); then
    if [ "$GO_VERSION" -lt 150 ]; then
      echo "Go version too low, skipping linux/arm-7..."
    else
      echo "Bootstrapping linux/arm-7..."
      CC=arm-linux-gnueabihf-gcc-5 GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=1 CGO_CFLAGS="-march=armv7-a" CGO_CXXFLAGS="-march=armv7-a" go install std

      echo "Compiling for linux/arm-7..."
      CC=arm-linux-gnueabihf-gcc-5 CXX=arm-linux-gnueabihf-g++-5 HOST=arm-linux-gnueabihf PREFIX=/usr/arm-linux-gnueabihf CFLAGS="-march=armv7-a -fPIC" CXXFLAGS="-march=armv7-a -fPIC" $BUILD_DEPS /deps ${DEPS_ARGS[@]}
      export PKG_CONFIG_PATH=/usr/arm-linux-gnueabihf/lib/pkgconfig

      if [[ "$USEMODULES" == false ]]; then
        CC=arm-linux-gnueabihf-gcc-5 CXX=arm-linux-gnueabihf-g++-5 GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=1 CGO_CFLAGS="-march=armv7-a -fPIC" CGO_CXXFLAGS="-march=armv7-a -fPIC" go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
      fi
      CC=arm-linux-gnueabihf-gcc-5 CXX=arm-linux-gnueabihf-g++-5 GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=1 CGO_CFLAGS="-march=armv7-a -fPIC" CGO_CXXFLAGS="-march=armv7-a -fPIC" go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $BM -o "/build/$NAME-linux-arm-7`extension linux`" $PACK_RELPATH

      echo "Cleaning up Go runtime for linux/arm-7..."
      rm -rf /usr/local/go/pkg/linux_arm
    fi
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "arm64" ]); then
    if [ "$GO_VERSION" -lt 150 ]; then
      echo "Go version too low, skipping linux/arm64..."
    else
      echo "Compiling for linux/arm64..."
      CC=aarch64-linux-gnu-gcc-5 CXX=aarch64-linux-gnu-g++-5 HOST=aarch64-linux-gnu PREFIX=/usr/aarch64-linux-gnu $BUILD_DEPS /deps ${DEPS_ARGS[@]}
      export PKG_CONFIG_PATH=/usr/aarch64-linux-gnu/lib/pkgconfig

      if [[ "$USEMODULES" == false ]]; then
        CC=aarch64-linux-gnu-gcc-5 CXX=aarch64-linux-gnu-g++-5 GOOS=linux GOARCH=arm64 CGO_ENABLED=1 go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
      fi
      CC=aarch64-linux-gnu-gcc-5 CXX=aarch64-linux-gnu-g++-5 GOOS=linux GOARCH=arm64 CGO_ENABLED=1 go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $BM -o "/build/$NAME-linux-arm64`extension linux`" $PACK_RELPATH
    fi
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "mips64" ]); then
    if [ "$GO_VERSION" -lt 170 ]; then
      echo "Go version too low, skipping linux/mips64..."
    else
      echo "Compiling for linux/mips64..."
      CC=mips64-linux-gnuabi64-gcc-5 CXX=mips64-linux-gnuabi64-g++-5 HOST=mips64-linux-gnuabi64 PREFIX=/usr/mips64-linux-gnuabi64 $BUILD_DEPS /deps ${DEPS_ARGS[@]}
      export PKG_CONFIG_PATH=/usr/mips64-linux-gnuabi64/lib/pkgconfig

      if [[ "$USEMODULES" == false ]]; then
        CC=mips64-linux-gnuabi64-gcc-5 CXX=mips64-linux-gnuabi64-g++-5 GOOS=linux GOARCH=mips64 CGO_ENABLED=1 go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
      fi
      CC=mips64-linux-gnuabi64-gcc-5 CXX=mips64-linux-gnuabi64-g++-5 GOOS=linux GOARCH=mips64 CGO_ENABLED=1 go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $BM -o "/build/$NAME-linux-mips64`extension linux`" $PACK_RELPATH
    fi
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "mips64le" ]); then
    echo 'MIPS is unsupported in xgo-base:nano' >&2
    exit 2
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "mips" ]); then
    echo 'MIPS is unsupported in xgo-base:nano' >&2
    exit 2
  fi
  if ([ $XGOOS == "." ] || [ $XGOOS == "linux" ]) && ([ $XGOARCH == "." ] || [ $XGOARCH == "mipsle" ]); then
    if [ "$GO_VERSION" -lt 180 ]; then
      echo "Go version too low, skipping linux/mipsle..."
    else
      echo "Compiling for linux/mipsle..."
      CC=mipsel-linux-gnu-gcc-5 CXX=mipsel-linux-gnu-g++-5 HOST=mipsel-linux-gnu PREFIX=/usr/mipsel-linux-gnu $BUILD_DEPS /deps ${DEPS_ARGS[@]}
      export PKG_CONFIG_PATH=/usr/mipsle-linux-gnu/lib/pkgconfig

      if [[ "$USEMODULES" == false ]]; then
        CC=mipsel-linux-gnu-gcc-5 CXX=mipsel-linux-gnu-g++-5 GOOS=linux GOARCH=mipsle CGO_ENABLED=1 go get $V $X "${T[@]}" --ldflags="$V $LD" -d $PACK_RELPATH
      fi
      CC=mipsel-linux-gnu-gcc-5 CXX=mipsel-linux-gnu-g++-5 GOOS=linux GOARCH=mipsle CGO_ENABLED=1 go build $V $X $MOD "${T[@]}" --ldflags="$V $LD" $BM -o "/build/$NAME-linux-mipsle`extension linux`" $PACK_RELPATH
    fi
  fi
  # Check and build for Windows targets
  if [ $XGOOS == "." ] || [[ $XGOOS == windows* ]]; then
    echo 'Windows is unsupported in xgo-base:nano' >&2
    exit 2
  fi
  # Check and build for OSX targets
  if [ $XGOOS == "." ] || [[ $XGOOS == darwin* ]]; then
    # Split the platform version and configure the deployment target
    PLATFORM=`echo $XGOOS | cut -d '-' -f 2`
    if [ "$PLATFORM" == "" ] || [ "$PLATFORM" == "." ] || [ "$PLATFORM" == "darwin" ]; then
      PLATFORM=10.6 # OS X Snow Leopard
    fi
    export MACOSX_DEPLOYMENT_TARGET=$PLATFORM

    # Strip symbol table below Go 1.6 to prevent DWARF issues
    LDSTRIP=""
    if [ "$GO_VERSION" -lt 160 ]; then
      LDSTRIP="-s"
    fi
    # Build the requested darwin binaries
    if [ $XGOARCH == "." ] || [ $XGOARCH == "amd64" ]; then
      echo "Compiling for darwin-$PLATFORM/amd64..."
      CC=o64-clang CXX=o64-clang++ HOST=x86_64-apple-darwin15 PREFIX=/usr/local $BUILD_DEPS /deps ${DEPS_ARGS[@]}
      if [[ "$USEMODULES" == false ]]; then
        CC=o64-clang CXX=o64-clang++ GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 go get $V $X "${T[@]}" --ldflags="$LDSTRIP $V $LD" -d $PACK_RELPATH
      fi
      CC=o64-clang CXX=o64-clang++ GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 go build $V $X $MOD "${T[@]}" --ldflags="$LDSTRIP $V $LD" $R $BM -o "/build/$NAME-darwin-$PLATFORM-amd64$R`extension darwin`" $PACK_RELPATH
    fi
    if [ $XGOARCH == "." ] || [ $XGOARCH == "386" ]; then
      echo 'Mac OSX 32-bit is unsupported in xgo-base:nano' >&2
      exit 2
    fi
    # Remove any automatically injected deployment target vars
    unset MACOSX_DEPLOYMENT_TARGET
  fi
  # Check and build for iOS targets
  if [ $XGOOS == "." ] || [[ $XGOOS == ios* ]]; then
      echo 'iOS is unsupported in xgo-base:nano' >&2
      exit 2
  fi
done

# Clean up any leftovers for subsequent build invocations
echo "Cleaning up build environment..."
rm -rf /deps

for dir in `ls /usr/local`; do
  keep=0

  # Check against original folder contents
  for old in $USR_LOCAL_CONTENTS; do
    if [ "$old" == "$dir" ]; then
      keep=1
    fi
  done
  # Delete anything freshly generated
  if [ "$keep" == "0" ]; then
    rm -rf "/usr/local/$dir"
  fi
done
