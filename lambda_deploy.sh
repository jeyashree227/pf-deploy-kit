#!/usr/bin/env bash

######## Convert to Ruby/Python/Perl ########

# Disable output pagination
export PAGER='cat'

# Function: Helper text for current step
print_section_info() {
    echo "############################################################################"
    echo "# $1"
    echo "############################################################################"
}

# Function: Check for AWS error
checkForAWSError() {
    code=$1
    if [[ $code != 0 ]]; then
        echo "ERROR: Non 0 exit code from aws cli, exiting"
        exit 1
    fi
}

# Function: check script environment
get_env() {
    local uname
    uname=$(uname -s)
    if [[ "$uname" == "Darwin" ]]; then
        platform='OSX'
    else
        platform='Linux'
    fi
}

# Checking operating system
print_section_info "Checking operating system"
get_env
echo "Running on $platform"

# Checking deploy context
print_section_info "Checking deploy context"
deploy_contexts=("Staging" "Production")
deploy_context=$1
if [[ ! " ${deploy_contexts[*]} " =~ "$deploy_context" ]]; then
    echo "Unknown context. Expected: $(
        IFS=$'|'
        echo "${deploy_contexts[*]}"
    )"
    exit 1
fi
deploy_context_lowercase=$(echo "$deploy_context" | tr '[:upper:]' '[:lower:]')
echo "Context is $deploy_context"

# Update function code
print_section_info "Update function code"
if [[ $ALL_ENVIRONMENTS = 'true' ]]; then
    function_name=$PROJECT_NAME
else
    function_name=$deploy_context_lowercase"_"$PROJECT_NAME
fi
artefact_path=$(pwd)"/"$RELATIVE_PATH_ARTEFACT
rev_id=$(aws lambda update-function-code --function-name "$function_name" \
    --zip-file "fileb://$artefact_path" \
    --query 'RevisionId' --output text)
checkForAWSError $?
echo "Function code revision id: $rev_id"
