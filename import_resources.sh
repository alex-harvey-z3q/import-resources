#!/usr/bin/env bash

# shellcheck disable=SC2059

# This file defines functions that are expected to be included
# by import scripts or empty functions (like "ABCs") that are to be implemented.

if [[ "$(uname -s)" = "Darwin" ]] ; then
  brew_prefix="$(brew --prefix)"
  if [[ ! -x "$brew_prefix"/opt/coreutils/libexec/gnubin/mktemp ]] ; then
    echo "On MacOS you need to install coreutils:"
    echo "$ brew install coreutils"
    exit 1
  fi

  if [[ ! -x "$brew_prefix"/bin/gsed ]] ; then
    echo "On MacOS you need to install GNU sed:"
    echo "$ brew install gnu-sed"
    exit 1
  fi

  shopt -s expand_aliases

  # shellcheck disable=SC2139
  alias mktemp="$brew_prefix"/opt/coreutils/libexec/gnubin/mktemp

  # shellcheck disable=SC2139
  alias sed="$brew_prefix"/bin/gsed
fi

_framework_usage() {
  local message
  message="$1"

  cat <<'EOF'
Example usage:

sceptre_resource_id="IAMRole"              # The resource ID used in the Sceptre/CloudFormation template
sceptre_stack_name="iam-generic"           # The Sceptre stack name that appears in the source block
importable_resource_type="AWS::IAM::Role"  # The CloudFormation resource type that supports import resources
importable_parameter_name="RoleName"       # The CloudFormation parameter name of the resource to be imported
script_name="$(basename "$0")"             # The name of the calling script
suggested_output_dir="iam"                 # The suggested output path relative path part for the generated values file. This
                                           #   would be relative to the account values file dir like nonprod/streamotion-datalake-nonprod

source "$(dirname "$0")/_import_framework.sh"
EOF

  exit 1
}

usage() {
  cat <<EOF
Usage: [DEV_MODE=true] $0 [-h] [-g] [-o OUTPUT_PATH] [-c COMMON_ENV] RESOURCE_NAME
A script to import resources into Sceptre
  -h              Show this message
  -g              Generate the values file only (no import)
  -o OUTPUT_PATH  Set your a custom location for generated values file
  -c COMMON_ENV   Path to common-env.yaml. Defaults to
                  \$SCEPTRE_ENV_DIR/*/\$AWS_PROFILE/common-env.yaml
EOF
  exit 1
}

[[ -z "$sceptre_resource_id" ]] && _framework_usage "sceptre_resource_id not set"
[[ -z "$sceptre_stack_name" ]]  && _framework_usage "sceptre_stack_name not set"
[[ -z "$importable_resource_type" ]]  && _framework_usage "importable_resource_type not set"
[[ -z "$importable_parameter_name" ]] && _framework_usage "importable_parameter_name not set"
[[ -z "$script_name" ]]          && _framework_usage "script_name not set"
[[ -z "$suggested_output_dir" ]] && _framework_usage "suggested_output_dir not set"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

sceptre_environment="${SCEPTRE_ENV_DIR:-/app/sceptre-environment}"
sceptre_templates="${SCEPTRE_TEMPLATE_DIR:-/app/streamotion-platform-sceptre}"

initial_template="/tmp/initial-template.yaml"
list_resources_report="/tmp/resources.json"

# Tags to ignore when importing custom resource tags.
#
tags_to_ignore='["Environment","Contact","Team","Department","Project","SourceControlPath","Version","Creator"]'


# _sanity_check checks options and globals after opts have been
# read in.
#
_set_globals() {
  if ! template_version="$(< "$sceptre_templates"/stacks/"$sceptre_stack_name"/VERSION)" ; then
    echo "Unable to set template_version"
    usage
  fi

  if [[ -z "$importable_resource_name" ]] ; then
    importable_resource_name="$1"
  fi

  if [[ -z "$importable_resource_name" ]] ; then
    usage
  fi

  if [[ ! -d "$sceptre_environment" ]] ; then
    echo "Could not find the sceptre-environment at $sceptre_environment, aborting..."
    exit 1
  fi

  if [[ ! -d "$sceptre_templates" ]] ; then
    echo "Could not find the streamotion-platform-templates at $sceptre_templates, aborting..."
    exit 1
  fi

  # Needed to ensure that we use the correct template version.
  #
  if ! grep -qw refs/heads/master "$sceptre_templates"/.git/HEAD && [[ -z "$DEV_MODE" ]] ; then
    echo "Ensure that the master branch is checked out in $sceptre_templates"
    exit 1
  fi

  (cd "$sceptre_templates"
   local_master_hash="$(git rev-parse master)"
   remote_master_hash="$(git rev-parse origin/master)"

   if [[ "$local_master_hash" != "$remote_master_hash" ]] ; then
     echo "Local master branch is not in sync with upstream"
     exit 1
   fi) || exit 1
}

# The get_opts function.
#
# Input Globals:
#   @: Array of args passed on the CLI.
#
# Output Globals:
#   generate_values_file_only: generate-only mode -g
#   importable_resource_name: The actual name of the resource.
#   output_path: The path to save the output file.
#   template_version: The discovered latest version of the Sceptre template.
#   common_env: (Optional). The path to common-env.yaml.
#
get_opts() {
  local opt OPTIND OPTARG
  local local_master_hash remote_master_hash

  while getopts "hgo:c:" opt ; do
    case "$opt" in
      h) usage ;;
      g) generate_values_file_only=1 ;;
      o) output_path="$OPTARG" ;;
      c) common_env="$OPTARG" ;;
      \?)
        _print_err "Invalid option: $OPTARG"
        usage
        ;;
    esac
  done

  shift $((OPTIND - 1))

  _set_globals "$@"
}

#------------------------------------------------------------------------------------
# Helper functions used anywhere (i.e. in this library and plugins).
#------------------------------------------------------------------------------------

# A printer to print messages to stderr.
#
# Input Arguments:
#   $1=message: the message to print.
#
_print_err() {
  local message="$1"
  printf "%s\n" "$message" >&2
}

# Print a warning in red.
#
# Input Arguments:
#   $1=message: the message to print.
#
# Output Text:
#   The message.
#
_warning() {
  local message="$1"
  # shellcheck disable=SC2059
  printf "${RED}!!!WARNING!!! ${message}${RESET}\n" >&2
}

# An indenter.
#
# Input Args:
#   $1==indent: 2-space indent levels to indent by.
#
# Input Text:
#   The text to indent.
#
# Output Text:
#   The indented text.
#
_indent() {
  local indent="$1"
  local indent_string real_indent
  real_indent="$(( indent * 2 ))"
  indent_string="$(printf "%${real_indent}s" " ")"
  sed '
    s/^/'"$indent_string"'/
    s/^  *$//  # But do not indent blank lines.
  '
}

# Print a new line.
#
_newline() {
  printf "\n"
}

# Convert an input like CAMEL_CASE to CamelCase.
#
# Input Args:
#   $1==input: A string like CAMEL_CASE
#
# Output Text:
#   A string like CamelCase
#
_camel_case() {
  local input="$1"
  if [[ "$input" =~ ^[A-Z_]+$ ]] ; then
    echo "$input" | awk 'BEGIN{FS="_";OFS=""}{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
  else
    echo "$input"
  fi
}

# Delete any unwanted blank lines from the end
# of a file where the file is expected to be a
# generated values file.
#
# Input Args:
#   $1==input_file: The file to edit.
#
_delete_blanks() {
  local input_file="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  tac "$input_file" | sed '/./,$!d' | tac > "$tmp_file" && mv "$tmp_file" "$input_file"
}

# Set the path of common-env.yaml.
#
# Input Globals:
#   AWS_PROFILE
#
# Output Globals:
#   common_env: The full path to common-env.yaml.
#
_set_common_env_path() {
  if [[ -n "$common_env" ]] ; then
    return
  fi

  common_env="$(echo "$sceptre_environment"/*/"$AWS_PROFILE"/common-env.yaml)"

  if [[ "$common_env" == *"*"* ]] || [[ "$common_env" == *" "* ]] ; then
    echo "Could not set common-env.yaml, got $common_env"
    exit 1
  fi
}

#------------------------------------------------------------------------------------
# Helper functions to wrap calls to JQ.
#------------------------------------------------------------------------------------

# All functions assume an API response
# is saved in $temp_file or a file referenced by a global via -t.

# A function that wraps jq -r.
#
_jq_r() {
  local temp_file="$temp_file"

  if [[ "$1" = "-t" ]] ; then
    temp_file="$2"
    shift 2
  fi

  local script="$1"
  shift

  jq -r "$@" "$script" "$temp_file"
}

# A function that wraps jq -c.
# This minifies the response.
#
_jq_c() {
  local temp_file="$temp_file"

  if [[ "$1" = "-t" ]] ; then
    temp_file="$2"
    shift 2
  fi

  jq -c "$1" "$temp_file"
}

# A function that wraps _jq_r
# and returns YAML output.
#
# By default a newline is added at the
# end of the block. This can be suppressed
# by passing --no-newline as the first
# arg.
#
_jq_r_to_yaml() {
  if [[ "$1" = "--no-newline" ]] ; then
    local no_newline=1
    shift
  fi
  local output
  output="$(_jq_r "$@")"
  if [[ -n "$output" ]] ; then
    cfn-flip <<< "$output"
    [[ -z "$no_newline" ]] && printf "\n"
  fi
}

# A function that compares a
# specific API response against
# the real one in $temp_file.
#
_jq_response_is_equal() {
  local temp_file="$temp_file"

  if [[ "$1" = "-t" ]] ; then
    temp_file="$2"
    shift 2
  fi

  [[ "$(_jq_c -t "$temp_file" '.')" = "$1" ]]
}

# A function that checks for
# the opposite.
#
_jq_response_is_not_equal() {
  ! _jq_response_is_equal "$@"
}

#------------------------------------------------------------------------------------
# Other helper functions for API responses.
#------------------------------------------------------------------------------------

# A function that checks if an
# API response is empty.
#
_response_is_empty() {
  local temp_file="$temp_file"

  if [[ "$1" = "-t" ]] ; then
    temp_file="$2"
    shift 2
  fi

  [[ -z "$(<"$temp_file")" ]]
}

# A function that checks for
# the opposite.
#
_response_is_not_empty() {
  local temp_file="$temp_file"

  if [[ "$1" = "-t" ]] ; then
    temp_file="$2"
    shift 2
  fi

  [[ -n "$(<"$temp_file")" ]]
}

# A function that uses grep
# to simply check if the response
# contains a pattern.
#
_seen() {
  local input_file="$temp_file"

  if [[ "$1" = "-t" ]] ; then
    input_file="$2"
    shift 2
  fi

  grep -qw "$1" "$input_file"
}

# Negation of _seen.
#
_not_seen() {
  ! _seen "$@"
}

#------------------------------------------------------------------------------------
# Helper functions used by default implementations of our public functions.
#------------------------------------------------------------------------------------

# Set the output_path, the dir where the generated
# Sceptre values file will be saved.
#
# Input Globals:
#   common_env: The path to common-env.yaml.
#   suggested_output_dir: the subdir suggested
#     as output dir.
#
# Output Globals:
#   output_path: The full path to the output dir.
#
_set_output_path() {
  [[ -n "$output_path" ]] && return
  output_path="$(dirname "$common_env")/$suggested_output_dir"

  if [[ ! -d "$output_path" ]] ; then
    mkdir -p "$output_path"
  fi
}

# Print the template_bucket_name from common-env.yaml
#
# Output Text:
#   The template bucket name.
#
_set_template_bucket() {
  template_bucket_name="$(yq -r .template_bucket_name "$common_env")"
}

# Push the initial template to the template bucket.
#
# Input Globals:
#   template_bucket_name: The CloudFormation template bucket (from common-env.yaml).
#
_push_template() {
  (set -x ; aws s3 cp "$initial_template" s3://"$template_bucket_name"/)
}

# Print the reason for a change set failure and then exit.
#
# Input Globals:
#   stack_name: The stack name.
#
_change_set_failure() {
  local reason
  reason="$(aws cloudformation describe-change-set --change-set-name "ImportChangeSet" --stack-name "$stack_name" | jq -r .StatusReason)"
  # shellcheck disable=SC2059
  printf "${RED}${reason}${RESET}\n"
  exit 1
}

# Create the change set to import resources.
#
# Input Globals:
#   initial_template: The initial CloudFormation template used during import.
#   template_bucket_name: The template bucket.
#   stack_name: The stack name.
#
_create_change_set() {
  local resources_to_import base_name template_url

  resources_to_import="$(resources_to_import | jq -c .)"
  base_name="$(basename "$initial_template")"
  template_url="https://$template_bucket_name.s3.ap-southeast-2.amazonaws.com/$base_name"

  (set -x ; aws cloudformation create-change-set --stack-name "$stack_name" \
     --change-set-name "ImportChangeSet" --change-set-type "IMPORT" \
     --resources-to-import "$resources_to_import" --template-url "$template_url" \
     --capabilities "CAPABILITY_NAMED_IAM"

   aws cloudformation wait change-set-create-complete --stack-name "$stack_name" \
     --change-set-name "ImportChangeSet")

  # shellcheck disable=SC2181
  [[ "$?" -ne 0 ]] && _change_set_failure
}

# Execute the change set to complete importing the resources.
#
# Input Globals:
#   stack_name: The stack name.
#
_execute_change_set() {
  (set -x
   aws cloudformation execute-change-set --change-set-name "ImportChangeSet" --stack-name "$stack_name"
   aws cloudformation wait stack-import-complete --stack-name "$stack_name")
}

# Add the stack version tag. This is to allow GHA to then do an update stack on it
# without a -f.
#
# Input Globals:
#   stack_name: The stack name.
#   template_version: The version of the Sceptre stack e.g. 1.7.0.
#
_add_version_tag() {
  (set -x
   aws cloudformation update-stack --stack-name "$stack_name" --use-previous-template --tags "Key=Version,Value=$template_version" --capabilities "CAPABILITY_NAMED_IAM"
   aws cloudformation wait stack-update-complete --stack-name "$stack_name")
}

# A function that is expected to be called by generate_final_values_file
# in an edge case e.g. Redshift.
_gha_skip_deploy() {
  printf "#gha skip-deploy\n"
}

# A function that is expected to be called by generate_final_values_file
# below. It generates the header of the final values file.
#
# Input Globals:
#   script_name: The name of the import script e.g. import_iam_generic.sh.
#   sceptre_stack_name: The name of the Sceptre stack e.g. iam-generic.
#   template_version: The version of the Sceptre stack e.g. 1.7.0.
#
_header() {
  cat <<EOF
# Generated by $script_name
---
source:
  path: $sceptre_stack_name
  version: $template_version

EOF
}


#------------------------------------------------------------------------------------
# From here, these functions all must be provided either using the implementation
# here or in the import script.
#------------------------------------------------------------------------------------

# Generate the JSON file that represents the resources to import and
# passed to the --resources-to-import argument of the import-resources
# command.
#
# This function would normally be used as-is other than in the case where, for
# example, you wish to import more than one resource.
#
# Input Globals:
#   importable_resource_type: The resource type to import.
#   sceptre_resource_id: The logical resource ID as given in the Sceptre
#     CloudFormation template.
#   importable_parameter_name: CloudFormation's name for the attribute.
#   importable_resource_name: The actual name of the resource.
#
# Output Text:
#   The JSON doc.
#
resources_to_import() {
  cat <<EOF
[{
  "ResourceType": "$importable_resource_type",
  "LogicalResourceId": "$sceptre_resource_id",
  "ResourceIdentifier": {
    "$importable_parameter_name": "$importable_resource_name"
  }
}]
EOF
}

# Generate the intermediate CloudFormation template used to create
# the intermediate CloudFormation stack (i.e. prior to Sceptre's
# template taking over the stack config).
#
# This function should be reimplemented if it needs to be customised.
#
# Input Globals:
#   sceptre_resource_id: The resource ID used in the Sceptre/CloudFormation
#     template e.g. IAMRole.
#   importable_resource_type: The CloudFormation resource type of the
#     resource to be imported e.g. AWS::IAM::Role.
#   importable_parameter_name: The CloudFormation parameter name of the
#     resource to be imported e.g. RoleName.
#
# Output Text:
#   A valid CloudFormation template.
#
generate_intermediate_cloudformation_template() {
  cat <<EOF
---
AWSTemplateFormatVersion: '2010-09-09'
Description: Initial import of $sceptre_stack_name

Parameters: {}

Resources:
  $sceptre_resource_id:
    Type: $importable_resource_type
    DeletionPolicy: Retain
    Properties:
      $importable_parameter_name: $importable_resource_name

Outputs: {}
EOF
}

# A function to generate the Sceptre values file. It typically
# begins by calling _header from above.
#
# NOTE: THE IMPLEMENTATION OF THIS FUNCTION IS THE MAIN PURPOSE
# OF THE PLUGINS.
#
generate_final_values_file() {
  :
}

# A function that creates temp files for saving API responses.
# (Optional). Define this if you want the API responses saved.
#
setup_temp() {
  :
}

# A function for setting up other custom variables needed by
# plugins.
# (Optional). See for example security_group_generic.sh.
#
setup_custom() {
  :
}

# A function that will list the available resources of the type
# that is being imported. It will save them as a JSON file in
# $list_resources_report.
#
# Note that the primary purpose of this function is sanity
# checking in conjunction with check_resource_exists. Please
# use describe_resource to populate $temp_file in generation
# of the values file.
#
# If the described resource is a single resource already found
# in $list_resources_report, use the pattern found e.g.
# in iam_generic.sh:
#
# list_resources() {
#   aws iam list-roles > "$list_resources_report"
# }
#
# describe_resource() {
#   jq --arg r "$importable_resource_name" '.Roles[] | select(.RoleName==$r)' "$list_resources_report" > "$temp_file"
# }
#
# Input Globals:
#   list_resources_report: The name of the file to output to.
#
list_resources() {
  :
}

# A function to verify that the resource to import actually
# exists. It should print an error message otherwise and then exit.
#
# Note that another common pattern is e.g. in import/iam_generic.sh:
#
# list_resources() {
#   aws iam list-roles > "$list_resources_report"
# }
#
# check_resource_exists() {
#   if ! jq --arg i "$importable_resource_name" 'any(.Roles[]; .RoleName == $i)' "$list_resources_report" | grep -q true ; then
#     echo "Role $importable_resource_name not found; exiting"
#     exit 1
#   fi
# }
#
# In this implementation, list_resources emits the JSON response of
# an API "list resources" command.
#
# But that pattern will always need to be implemented in the plugins,
# and can't be implemented here in the framework.
#
# The implementation in framework can be used if `list_resources` emits
# a simple list of resources as e.g. in `import/s3_bucket_generic.sh`.
#
check_resource_exists() {
  if ! grep -qw "^$importable_resource_name$" "$list_resources_report" ; then
    echo "Resource $importable_resource_name not found; exiting"
    exit 1
  fi
}

# A function that if defined runs a describe-resource-like command
# to prepopulate $temp_file.
#
describe_resource() {
  :
}

# A function that defines the Sceptre stack name as the Sceptre
# template will later define it.
#
# This function will often need to be reimplemented, as Sceptre's
# logic for setting the stack name is often quite inconsistent.
#
set_stack_name() {
  stack_name="$importable_resource_name"-"$sceptre_stack_name"
}

# A function to return the CommonTags block that receives
# a custom-defined get_tagging function.
#
# Usage:
#
# In practice the function is used as follows:
#
# 1. Define get_tagging that saves to a temp file.
#
# get_tagging() {
#   aws iam list-role-tags --role-name "$importable_resource_name" > "$temp_file_list_role_tags"
# }
#
# 2. Define _custom_tags that wraps custom_tags and points to that temp file:
#
# _custom_tags() {
#   custom_tags -k KEY_NAME -t "$temp_file_list_role_tags"
# }
#
# 3. In generate_final_values_file call _custom_tags.
#
# Input Args:
#   -k KEY_NAME (default Tags) e.g. -k TagSet. The name of
#               the key used in the response from get
#               tagging API. This tends to be "Tags" but
#               could be e.g. "TagSet" (see aws s3
#               get-bucket-tagging).
#
#   -t TEMP_FILE (default $temp_file). The path to the
#               temp_file that saved the response from
#               the Get Tags API.
#
custom_tags() {
  local tag_key="Tags"

  if [[ "$1" = "-k" ]] ; then
    tag_key="$2"
    shift 2
  fi

  local temp_file="$temp_file"

  if [[ "$1" = "-t" ]] ; then
    temp_file="$2"
    shift 2
  fi

  _print_err "Importing custom tags if any..."

  if ! get_tagging ; then
    return
  fi

  # shellcheck disable=SC2016
  _jq_r_to_yaml -t "$temp_file" '
    (
      .[$tagKey] | map(
        select(.Key as $k | ($ignore | index($k) | not) and ($k | startswith("aws:") | not))
      ) | reduce .[] as $item ({}; .[$item.Key] = $item.Value)
    ) as $filteredTags
    | if $filteredTags == {} then empty else {CommonTags: $filteredTags} end
  ' --arg tagKey "$tag_key" --argjson ignore "$tags_to_ignore"
}

# A function to return tags for the importable resource. See above.
#
get_tagging() {
  :
}

# A simple function that adds presentation around generate_final_values_file.
#
_generate_values() {
  local resource_name="$1"
  local output_path="$2"
  local final_values="$output_path/${resource_name}.yaml"

  printf "${YELLOW}GENERATING SCEPTRE TEMPLATE${RESET}\n"

  generate_final_values_file > "$final_values"
  _delete_blanks "$final_values"

  printf "${GREEN}Generated values file in $final_values${RESET}\n"
}

# Import the stack. The pathway for a full import of
# a stack and generate its Sceptre template.
#
# The caller should not redefine this thus it is marked private.
# The caller *sometimes* may need to redefine generate_intermediate_cloudformation_template
# instead.
#
# Output Globals:
#   final_values: The final values file, used again in
#     final_launch_steps.
#
_import() {
  _set_common_env_path
  _set_output_path
  _set_template_bucket

  set_stack_name

  final_values="$output_path/$importable_resource_name.yaml"

  printf "${YELLOW}IMPORTING RESOURCES${RESET}\n"
  generate_intermediate_cloudformation_template > "$initial_template"

  _push_template
  _create_change_set
  _execute_change_set
  _add_version_tag
}

# Generate. A function to generate the Sceptre values file.
#
# The caller should not redefine this thus it is marked private.
# The caller would normally define generate_final_values_file instead.
#
# Input Args:
#   $1==importable_resource_name: The resource name to import.
#
# Input Globals:
#   output_path: The path to save the output file.
#
# Output Globals:
#   importable_resource_name.
#
_generate() {
  [[ "$1" = "--no-message" ]] && local no_message=1
  [[ -z "$output_path" ]] && output_path="."
  final_values="$output_path/$importable_resource_name.yaml"
  generate_final_values_file > "$final_values"
  _delete_blanks "$final_values"
  [[ -z "$no_message" ]] && printf "${GREEN}Generated values file in $final_values${RESET}\n"
}

# Final launch steps. If special cases such as manual steps or CLI commands
# are required, reimplement this function.
#
# Input Globals:
#   final_values: the final values file, set above.
#
final_launch_steps() {
  printf "${YELLOW}Your generated values file is $final_values. To complete the migration:${RESET}\n"
}

#
# The main function.
#
main() {
  get_opts "$@"

  setup_temp
  list_resources
  setup_custom
  describe_resource
  check_resource_exists

  if [[ -n "$generate_values_file_only" ]] ; then
    _generate
    return
  fi

  _import
  _generate --no-message

  final_launch_steps
}
