#!/bin/bash

# Versions variables
nodeVersion="v24.12.0"
pnpmVersion="10"

declare -a script_env_vars

pdUrl=""
pdPath=""
targetFolder=""
resultsFolder="results"
fork="podman-desktop"
branch="main"
extTests=0
extRepo=""
extFork=""
extBranch=""
npmTarget="test:e2e"
podmanPath=""
envVars=""
secretFile=""
saveTraces=1
cleanMachine=1
scriptPaths=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --pdUrl) pdUrl="$2"; shift ;;
        --pdPath) pdPath="$2"; shift ;;
        --targetFolder) targetFolder="$2"; shift ;;
        --resultsFolder) resultsFolder="$2"; shift ;;
        --fork) fork="$2"; shift ;;
        --branch) branch="$2"; shift ;;
        --extRepo) extRepo="$2"; shift ;;
        --extTests) extTests="$2"; shift ;;
        --extFork) extFork="$2"; shift ;;
        --extBranch) extBranch="$2"; shift ;;
        --npmTarget) npmTarget="$2"; shift ;;
        --podmanPath) podmanPath="$2"; shift ;;
        --envVars) envVars="$2"; shift ;;
        --secretFile) secretFile="$2"; shift ;;
        --saveTraces) saveTraces="$2"; shift ;;
        --cleanMachine) cleanMachine="$2"; shift ;;
        --scriptPaths) scriptPaths="$2"; shift ;;
        *) ;;
    esac
    shift
done

echo "Reading envVars in script: '$envVars'"

# Create a env. vars from a string: VAR=VAL,VAR2=VAL
function load_variables() {
    echo "Loading Variables passed into image"
    echo "Env. Vars String: '$envVars'"
    if [ -n "$envVars" ]; then
        IFS=',' read -ra VARIABLES <<< "$envVars"
        for var in "${VARIABLES[@]}"; do
            echo "Processing $var"
            IFS='=' read -r name value <<< "$var"
            if [ -n "$value" ]; then
                export "$name"="$value"
                newValue="${!name}"
                script_env_vars+=("$name")
            else
                echo "Invalid variable assignment: $variable"
            fi
        done
    else
        echo "Input string is empty."
    fi
}

function execute_scripts() {
    echo "Loading Paths passed into image"
    echo "ScriptPaths String: '$scriptPaths'"
    if [[ -n "$scriptPaths" ]]; then
        scripts_folder="$resourcesPath"
        IFS=',' read -r -a paths <<< "$scriptPaths"
        for path in "${paths[@]}"; do
            path=$(echo "$path" | xargs)
            echo "Processing $path"
            script_path="$scripts_folder/$path"
            if [[ -f "$script_path" ]]; then
                echo "Executing $script_path"
                bash "$script_path"
            else
                echo "$script_path does not exist"
            fi
        done
    fi
}

function load_secrets() {
    if [ -n "$secretFile" ]; then
        secretFilePath="$resourcesPath/$secretFile"
        if [ -f $secretFilePath ]; then
            echo "Loading Secrets from file: $secretFilePath"
            while IFS='=' read -r key value || [ -n "$key" ]; do
                if [[ ! $key =~ ^\s*# && -n $key ]]; then
                    key=$(echo "$key" | sed 's/^[ \t]*//;s/[ \t]*$//')
                    value=$(echo "$value" | sed 's/^[ \t]*//;s/[ \t]*$//')
                    export "$key"="$value"
                    script_env_vars+=("$key")
                fi
            done < "$secretFilePath"
            echo "Secrets loaded from '$secretFilePath' and set as environment variables."
        else
            echo "Secret File path $secretFilePath does not exist"
        fi
    else
        echo "Secret file Parameter not set"
    fi
}

function clone_checkout() {
    local local_repo=$1
    local local_fork=$2
    local local_branch=$3
    echo "Working Dir: $workingDir"
    cd $workingDir
    echo "Cloning $local_repo"
    if [ -d $local_repo ]; then
        echo "$local_repo github repo exists"
    else
        repositoryURL="https://github.com/$local_fork/$local_repo.git"
        echo "Checking out $repositoryURL"
        git clone $repositoryURL
    fi
    cd $local_repo || exit
    echo "Fetching all branches and tags"
    git fetch --all
    echo "Checking out branch: $local_branch"
    git checkout $local_branch
}

function copy_exists() {
    local source=$1
    local target=$2
    if [ -e $source ]; then
        echo "Copying files from $source to $target"
        cp -r $source $target
    else
        echo "Path $source does not exist"
    fi
}

function collect_logs() {
    local folder="$1"
    mkdir -p "$workingDir/$resultsFolder/$folder"
    local source="$workingDir/$folder"
    local target="$workingDir/$resultsFolder/$folder"
    echo "Collecting the results from: $source, to: $target"

    local junits=()
    while IFS= read -r file; do
        [ -n "$file" ] && junits+=("$file")
    done < <(find "$source" -type f -name "junit*.xml" 2>/dev/null)

    local count=${#junits[@]}

    if [ "$count" -eq 0 ]; then
        echo "WARNING: No JUnit file found anywhere in $source"
    else
        if [ "$count" -gt 1 ]; then
            echo "WARNING: Expected exactly one JUnit file, but found $count! Proceeding with the first one."
        fi
        local junit="${junits[0]}"
        local target_path="$workingDir/$resultsFolder/junit-$folder.xml"
        echo "Found Junit file: $junit"
        echo "Copying $junit to $target_path"
        cp "$junit" "$target_path"
    fi

    if (( extTests == 1 )); then
        echo "Removing possible models from working directories"
        ls $source/**/output/**/*.gguf
        rm -rf $source/**/output/**/*.gguf
        echo "Removing possible VM files from **/images/*"
        ls $source/**/output/**/images/
        rm -rf $source/**/output/**/images/*
    fi

    ls $source/**/output/**/plugins/*
    rm -rf $source/**/output/**/plugins/*

    copy_exists "$source/output.log" $target
    copy_exists "$source/tests/output/" $target
    copy_exists "$source/tests/playwright/output/" $target
    copy_exists "$source/tests/playwright/tests/output/" $target
    echo "Removing resources artifacts"
    rm -rf $target/resources
    rm -rf $target/*/resources
    rm -rf $target/**/resources
    echo "Removing plugins from pd home dir - contains node_modules"
    rm -rf $target/**/plugins/*
    if [ -d "$target/traces" ]; then
        echo "Removing raw playwright trace files: ./**/traces/raw"
        rm -r "$target/traces/raw"
        if (( saveTraces == 0)); then
            echo "Removing all traces from test artifacts, mainly due capacity reasons"
            rm -rf "$target/traces"
        fi
    fi
}


echo "Podman desktop E2E runner script is being run on RHEL..."

if [ -z "$targetFolder" ]; then
    echo "Error: targetFolder is required"
    exit 1
fi

echo "Switching to a target folder: $targetFolder"
cd "$targetFolder" || exit
echo "Create a resultsFolder in targetFolder: $resultsFolder"
mkdir -p "$resultsFolder"
workingDir=$(pwd)
echo "Working location: $workingDir"

userProfile="$HOME"
toolsInstallDir="$userProfile/tools"
outputFile="pde2e-binary-path.log"
architecture=$(uname -m)
resourcesPath=$workingDir

load_variables
load_secrets

if [ ! -d "$toolsInstallDir" ]; then
    mkdir -p "$toolsInstallDir"
fi

# node installation
if ! command -v node &> /dev/null; then
    nodeUrl="https://nodejs.org/download/release/$nodeVersion/node-$nodeVersion-linux-x64.tar.xz"
    if [ ! -d "$toolsInstallDir/node-$nodeVersion-linux-x64" ]; then
        echo "Installing node $nodeVersion for linux x64"
        curl -o "$toolsInstallDir/node.tar.xz" "$nodeUrl"
        tar -xf $toolsInstallDir/node.tar.xz -C $toolsInstallDir
    fi
    if [ -d "$toolsInstallDir/node-$nodeVersion-linux-x64/bin" ]; then
        echo "Node Installation path found"
        export PATH="$PATH:$toolsInstallDir/node-$nodeVersion-linux-x64/bin"
    else
        echo "Node installation path not found"
    fi
fi

echo "Node.js Version: $(node -v)"
echo "npm Version: $(npm -v)"

# git — available via dnf on RHEL
if ! command -v git &> /dev/null; then
    echo "Installing git via dnf..."
    sudo dnf install -y git
fi
git --version

if ! command -v xvfb-run &> /dev/null; then
    echo "Installing xorg-x11-server-Xvfb via dnf..."
    sudo dnf install -y xorg-x11-server-Xvfb
fi

# Install pnpm
echo "Installing pnpm"
npm install -g pnpm@$pnpmVersion
echo "pnpm Version: $(pnpm --version)"

# Setup Podman path
if ! command -v podman &> /dev/null; then
    if [ -n "$podmanPath" ]; then
        echo "Setting podman binary location '$podmanPath' to PATH"
        export PATH="$PATH:$podmanPath"
    else
        echo "Podman is not installed and no podmanPath provided"
        exit 1
    fi
else
    if [ -n "$podmanPath" ]; then
        echo "Overriding podman PATH with provided podmanPath: $podmanPath"
        export PATH="$podmanPath:$PATH"
    fi
fi

# Terminate any running Podman Desktop instances
exit_status=0
echo "pid of running Podman Desktop instances:"
pgrep -f "Podman Desktop" || exit_status=$?
if (( exit_status == 0 )); then
    echo "Podman Desktop is running, terminating..."
    kill -9 $(pgrep -f "Podman Desktop")
else
    echo "No running Podman Desktop"
fi

if (( cleanMachine == 1 )); then
    echo "Cleaning up podman state..."
    podman system prune -f --volumes 2>/dev/null || true
    echo "Cleanup finished..."
fi

# Podman Desktop binary
podmanDesktopBinary=""

if [ -z "$pdPath" ]; then
    if [ -n "$pdUrl" ]; then
        echo "Downloading Podman Desktop from $pdUrl"
        curl -L -O "$pdUrl"
        pkgFile=$(realpath $(find . -maxdepth 1 -name "*podman-desktop*"))
        if [[ "$pkgFile" == *.rpm ]]; then
            echo "Installing Podman Desktop RPM: $pkgFile"
            sudo dnf install -y "$pkgFile"
            podmanDesktopBinary=$(which podman-desktop 2>/dev/null || find /usr -name podman-desktop -type f 2>/dev/null | head -1)
        else
            echo "Unknown Podman Desktop package format: $pkgFile"
            exit 1
        fi
    fi
else
    podmanDesktopBinary="$pdPath"
fi

if [ -n "$podmanDesktopBinary" ]; then
    echo "Setting PODMAN_DESKTOP_BINARY to: $podmanDesktopBinary"
    export PODMAN_DESKTOP_BINARY="$podmanDesktopBinary"
elif (( extTests == 1 )); then
    echo "Setting PODMAN_DESKTOP_ARGS to: $workingDir/podman-desktop"
    export PODMAN_DESKTOP_ARGS="$workingDir/podman-desktop"
fi

export CI=true
testsOutputLog="$workingDir/$resultsFolder/tests.log"

if [[ "$extTests" -eq 1 ]] && [ -n "$podmanDesktopBinary" ]; then
    echo "Running ext. tests and podman Desktop binary is specified, skipping checkout for podman-desktop"
else
    echo "Checking out Podman Desktop repository"
    clone_checkout "podman-desktop" $fork $branch
    cd "$workingDir/podman-desktop"
    echo "Installing dependencies and storing pnpm run output in: $testsOutputLog"
    pnpm install --frozen-lockfile 2>&1 | tee -a $testsOutputLog
    if [[ "$extTests" -eq 1 ]]; then
        echo "Building podman-desktop for extension e2e tests"
        pnpm test:e2e:build 2>&1 | tee -a $testsOutputLog
    fi
fi

if [[ "$extTests" -eq 1 ]]; then
    echo "Checking out extension repository: $extRepo"
    clone_checkout $extRepo $extFork $extBranch
fi

execute_scripts

if (( extTests == 1 )); then
    cd "$workingDir/$extRepo"
    echo "Add latest version of the @podman-desktop/tests-playwright into right package.json"
    if [ -d "$workingDir/$extRepo/tests/playwright" ]; then
        cd tests/playwright
    fi
    pnpm add -D @podman-desktop/tests-playwright@next
    cd "$workingDir/$extRepo"
    echo "Installing dependencies of $extRepo"
    pnpm install --frozen-lockfile 2>&1 | tee -a $testsOutputLog
    echo "Running the e2e playwright tests using target: $npmTarget"
    pnpm $npmTarget 2>&1 | tee -a $testsOutputLog
    collect_logs $extRepo
else
    echo "Running the e2e playwright tests using target: $npmTarget, binary path, if any: $podmanDesktopBinary"
    pnpm "$npmTarget" 2>&1 | tee -a $testsOutputLog
    collect_logs "podman-desktop"
fi

# Cleanup env vars / secrets
echo "Cleaning the host"
unset "${script_env_vars[@]}"

if [ -f "$resourcesPath/$secretFile" ]; then
    echo "Removing secrets file: $resourcesPath/$secretFile"
    rm "$resourcesPath/$secretFile"
fi

if (( cleanMachine == 1 )); then
    echo "Cleaning up podman state after tests"
    podman system prune -f --volumes 2>/dev/null || true
fi

if [ -n "$podmanDesktopBinary" ] && [[ "$pdUrl" == *.rpm ]]; then
    echo "Removing Podman Desktop RPM installation"
    sudo dnf remove -y podman-desktop 2>/dev/null || true
fi

echo "Script finished..."
