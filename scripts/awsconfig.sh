#!/bin/bash

# -----------------------------------------------------------------------------
# Script Name: awsconfig.sh
# Description: Retrieves temporary AWS STS credentials and exports them as
#              environment variables in the current shell session.
#
# Usage:
#   source ./awsconfig.sh [--serial-number <mfa_device_arn>] [--profile <profile_name>] [--duration <seconds>]
#
# Options:
#   --serial-number   (Optional) ARN of the MFA device. If provided, the script will prompt for MFA token code.
#   --profile         (Optional) AWS CLI profile to use.
#   --duration        (Optional) Duration in seconds for the temporary session (default: 28800).
#
# Examples:
#   source ./awsconfig.sh
#       Get temporary credentials with default profile and no MFA.
#
#   source ./awsconfig.sh --serial-number arn:aws:iam::123456789012:mfa/your-user --profile dev
#       Get temporary credentials using MFA and the 'dev' profile.
#
# Notes:
#   - You must have the AWS CLI installed and configured.
#   - You must have 'jq' installed to parse JSON.
#   - Must be sourced to export environment variables to your current shell session.
# -----------------------------------------------------------------------------

# Ensure the script is being sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: This script must be sourced, not executed directly."
    echo "Usage: source ./awsconfig.sh [options]"
    exit 1
fi

# Default duration
DURATION=28800

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --serial-number)
            SERIAL_NUMBER="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            return 1
            ;;
    esac
done

# Unset any existing AWS credentials in the environment
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN

# Build the base STS command
STS_COMMAND=(aws sts get-session-token --duration-seconds "$DURATION")

# Add serial number and token code if MFA is used
if [[ -n "$SERIAL_NUMBER" ]]; then
    read -p "Enter the MFA token code: " TOKEN_CODE
    STS_COMMAND+=(--serial-number "$SERIAL_NUMBER" --token-code "$TOKEN_CODE")
fi

# Add profile if provided
if [[ -n "$PROFILE" ]]; then
    STS_COMMAND+=(--profile "$PROFILE")
fi

# Print the command (for logging/debug)
echo "Requesting temporary AWS STS credentials using:"
echo "${STS_COMMAND[@]}"

# Run the command and capture output
RESPONSE_JSON=$("${STS_COMMAND[@]}")
if [[ $? -ne 0 ]]; then
    echo "Failed to get session token from STS."
    return 1
fi

# Check for jq
if ! command -v jq >/dev/null; then
    echo "Error: 'jq' is required but not installed. Please install jq first."
    return 1
fi

# Extract credentials
export AWS_ACCESS_KEY_ID=$(echo "$RESPONSE_JSON" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$RESPONSE_JSON" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$RESPONSE_JSON" | jq -r '.Credentials.SessionToken')
EXPIRATION=$(echo "$RESPONSE_JSON" | jq -r '.Credentials.Expiration')

# Display credentials and expiration
echo "Temporary AWS credentials set successfully:"
echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID"
echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY"
echo "AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN"
echo "Token expires at: $EXPIRATION"
echo "You can now run AWS CLI commands in this session."
