#!/bin/bash

function setup_kube_alias {
    local aws_profile=$1

    # Path to the YAML file
    local config_file="$HOME/.kube/config"

    # Find User Name based on AWS Profile
    local user_name=$(yq e ".users[] | select(.user.exec.env[]?.value == \"$aws_profile\") | .name" "$config_file")

    if [ -z "$user_name" ]; then
        return 1
    fi

    # Find Context Name based on User Name
    local context_name=$(yq e ".contexts[] | select(.context?.user == \"$user_name\") | .name" "$config_file")
    if [ -z "$context_name" ]; then
        return 1
    fi

    local contextrole=$(echo $context_name | sed 's/-eks//g')
    local alias_command="alias igo$contextrole='assume $aws_profile && kubectx $context_name'"
    echo "new alias: $alias_command"
    echo "$alias_command" >> $HOME/.zshrc
}

# Function to update kubeconfig for a specific profile
update_kubeconfig_for_profile() {
    local profile=$1
    local cluster=$2
    local region=$3
    local department=$4

    echo "Updating kubeconfig for profile $profile, cluster $cluster"
    role=$(echo $profile | grep -oP '(?<=/)[^-/]*-[^-/]*' | awk -F'-' '{print $2}')
    ACCOUNT_NUMBER=$(aws sts get-caller-identity --query 'Account' --output text)
    if [ -z "$department" ]; then
        aws eks update-kubeconfig --name $cluster --region $region --profile $profile --user-alias $cluster-$role
    else
        aws eks update-kubeconfig --name $cluster --region $region --profile $profile --user-alias $cluster-$role --role-arn arn:aws:iam::${ACCOUNT_NUMBER}:role/digitalidf-developer-$department
    fi
}

# Declare the department variable
department=""

# Prompt the user for their department and confirm
while true; do
    read -p "Please enter your department (or type 'no' if you don't know): " department
    # Remove leading and trailing spaces
    department=$(echo "$department" | sed 's/^[ \t]*//;s/[ \t]*$//')  
    if [ "$department" = "no" ]; then
        echo "Please run this script when you know:"
        echo "chmod +x config-aws-kube.sh"
        echo "./config-aws-kube.sh"
        exit 0
    fi
    read -p "You entered '$department'. Is this correct? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        break
    fi
done

KUBECONFIG="$HOME/.kube/config"
AWS_CONFIG_FILE="$HOME/.aws/config"

# Create directories if they do not exist
mkdir -p "$(dirname "$AWS_CONFIG_FILE")"
mkdir -p "$(dirname "$KUBECONFIG")"

# Remove existing files if they exist, then create new empty files
rm -f "$AWS_CONFIG_FILE"
touch "$AWS_CONFIG_FILE"
rm -f "$KUBECONFIG"
touch "$KUBECONFIG"
sed -i '/^alias igo/d' ~/.zshrc

# Run granted sso populate
granted sso populate --sso-region eu-west-1 https://d-936772b4a3.awsapps.com/start

# Define the default region you want to set
DEFAULT_REGION="il-central-1"

# Temporary file for storing modified content
TEMP_FILE=$(mktemp)


# Read the config file line by line
while IFS= read -r line
do
    echo "$line" >> "$TEMP_FILE"
    if [[ $line == \[profile* ]] && ! grep -q "region = " <<< "$line"; then
        echo "region = $DEFAULT_REGION" >> "$TEMP_FILE"
    fi
done < "$AWS_CONFIG_FILE"

# Replace the original file with the modified content
mv "$TEMP_FILE" "$AWS_CONFIG_FILE"


# Get all profiles from AWS config
profiles=$(grep '\[profile' $AWS_CONFIG_FILE | sed 's/\[profile \(.*\)\]/\1/')

for profile in $profiles
do
    echo "Processing profile: $profile"
    # Check if the assume script exists
    if [ ! -f /usr/local/bin/assume ]; then
        assume $profile
    fi

    # Source the assume script and force exit 0
    source /usr/local/bin/assume $profile || true
    clusters=$(aws eks list-clusters --output text --query "clusters[*]" --profile $profile)

    for cluster in $clusters
    do
        # Get cluster region
        region="il-central-1"
        
        # Update kubeconfig for this cluster
        update_kubeconfig_for_profile $profile $cluster $region $department
    done
done

echo "Kubeconfig updated for all"

while IFS= read -r line; do
    if [[ $line =~ \[profile\ (.*)\] ]]; then
        profile_name="${BASH_REMATCH[1]}"
        profile_name="${profile_name%"${profile_name##*[![:space:]]}"}"  # Remove trailing spaces
        setup_kube_alias "$profile_name"
    fi
done < "$AWS_CONFIG_FILE"
echo "done, the new aliases are in your .zshrc file"