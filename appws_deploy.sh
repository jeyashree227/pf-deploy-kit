#!/usr/bin/env bash

# Disable output pagination
export PAGER='cat'

# Convert repo name to lowercase
ECR_REPO_NAME=$(echo "$ECR_REPO_NAME" | tr '[:upper:]' '[:lower:]')
BITBUCKET_COMMIT_SHORT="${BITBUCKET_COMMIT::7}"

# Script variables
template_path='./aws_cli_templates/'
policy_path='./aws_cli_policies/'
log_retention_staging=7
log_retention_production=30 # Should match terraform
ecs_min_capacity=1
ecs_max_capacity=4
aws_ecr_repo_base_url="$AWS_ACCOUNT".dkr.ecr."$AWS_REGION".amazonaws.com

# Function: Helper text for current step
print_section_info() {
    echo "############################################################################"
    echo "# $1"
    echo "############################################################################"
}

# Function: Check for AWS error
checkForAWSError() {
    code=$1
    cleanup_images=$2
    cleanup_taskdef=$3
    if [[ $code != 0 ]]; then
        echo "ERROR: Non 0 exit code from aws cli, exiting"
        if [[ "$cleanup_images" == "yes" ]]; then
            aws ecr batch-delete-image --repository-name "$ECR_REPO_NAME" --image-ids imageTag="$tag" \
                --query 'imageIds[*].imageTag' --output text
            aws ecr batch-delete-image --repository-name "$ECR_REPO_NAME"_proxy --image-ids imageTag="$tag" \
                --query 'imageIds[*].imageTag' --output text
            echo "Removed images with tag $tag from ECR"
        fi
        if [[ "$cleanup_taskdef" == "yes" ]]; then
            local td_family
            td_family=$(aws ecs deregister-task-definition --task-definition "$service_name":"$taskdef_rev" \
                --query 'taskDefinition.family' --output text)
            echo "Removed task definition $td_family"
        fi
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
deploy_context_uppercase=$(echo "$deploy_context" | tr '[:lower:]' '[:upper:]')
echo "Context is $deploy_context"

# Checking deploy artefact type
print_section_info "Checking deploy artefact type"
deploy_types=("App" "Webservice")
deploy_type=$2
if [[ ! " ${deploy_types[*]} " =~ "$deploy_type" ]]; then
    echo "Unknown artefact type. Expected: $(
        IFS=$'|'
        echo "${deploy_types[*]}"
    )"
    exit 1
fi
deploy_type_lowercase=$(echo "$deploy_type" | tr '[:upper:]' '[:lower:]')
echo "Deploying $deploy_type ($ECR_REPO_NAME)"

# Create main repository if necessary and set lifecycle policy
print_section_info "Create main repository in ECR if necessary"
repo_arn=$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" \
    --query 'repositories[*].repositoryUri' --output text)
if [[ -z "$repo_arn" ]]; then
    repo_arn=$(aws ecr create-repository --repository-name "$ECR_REPO_NAME" --image-tag-mutability \
        MUTABLE --image-scanning-configuration scanOnPush=true \
        --query 'repository.repositoryArn' --output text)
    checkForAWSError $?
    echo "Repo created. Arn: $repo_arn"
else
    echo "Repo already exists. Arn: $repo_arn"
fi
repo_policy_id=$(aws ecr put-lifecycle-policy --repository-name "$ECR_REPO_NAME" --lifecycle-policy-text \
    "file://$policy_path/ecr_policy.json" --query 'registryId' --output text)
checkForAWSError $?
echo "Repo policy updated. Id: $repo_policy_id"

# Create proxy repository if necessary and set lifecycle policy
print_section_info "Create proxy repository in ECR if necessary"
repo_proxy_arn=$(aws ecr describe-repositories --repository-names "$ECR_REPO_NAME"_proxy \
    --query 'repositories[*].repositoryUri' --output text)
if [[ -z "$repo_proxy_arn" ]]; then
    repo_proxy_arn=$(aws ecr create-repository --repository-name "$ECR_REPO_NAME"_proxy --image-tag-mutability \
        MUTABLE --image-scanning-configuration scanOnPush=true \
        --query 'repository.repositoryArn' --output text)
    checkForAWSError $?
    echo "Repo created. Arn: $repo_proxy_arn"
else
    echo "Repo already exists. Arn: $repo_proxy_arn"
fi
repo_proxy_policy_id=$(aws ecr put-lifecycle-policy --repository-name "$ECR_REPO_NAME"_proxy --lifecycle-policy-text \
    "file://$policy_path/ecr_policy.json" --query 'registryId' --output text)
checkForAWSError $?
echo "Repo policy updated. Id: $repo_proxy_policy_id"

# Notification service only
# Create Email templates for notification service
print_section_info "Create Email templates for notification service"
template_folder="./src/templates/email"
if [[ -d "$template_folder" ]] && [[ $ECR_REPO_NAME = 'notification_service' ]]; then
    cnt=0
    for file in "$template_folder"/*.json; do
        cnt=$((cnt + 1))
        template_name=$(basename "$file" ".json")"_$deploy_context"
        subject=$(jq -r .subject "$file")
        #subject="${subject//'//'}"
        html=$(jq -r .html "$file")
        #html="${html//'//'}"
        text=$(jq -r .text "$file")
        #text="${text//'//'}"
        echo "Creating email template $template_name"
        export template_name
        export subject
        export text
        export html
        envsubst <$template_path/ses_email_template.template >$template_path/ses_email_template.json
        aws ses create-template --cli-input-json file://$template_path/ses_email_template.json ||
            aws ses update-template --cli-input-json file://$template_path/ses_email_template.json
        checkForAWSError $?
    done
    echo "Created/Updated $cnt email template(s) for the notification service."
fi

# Check if image with tag already exists
print_section_info "Checking if image with tag already exists"
tag="$deploy_context_lowercase"_"$BITBUCKET_COMMIT_SHORT"
image_exists=$(aws ecr describe-images --repository-name "$ECR_REPO_NAME" \
    --image-ids imageTag="$tag" --query 'length(imageDetails[*])' --output text)
if [[ $? != 0 || $image_exists -lt 1 ]]; then
    build_image=true
    echo "Image with tag $tag does not exist in repo. Image build required."
else
    echo "Image with tag $tag already exists in repo."
fi

# Build docker images
if [[ $build_image = 'true' ]]; then
    print_section_info "Build docker images"
    file=$(realpath ./Dockerfile."$deploy_context_lowercase")
    if [[ -f "$file" ]]; then
        # environment specific dockerfile - old
        docker build -q --file ./Dockerfile."$deploy_context_lowercase" -t "$ECR_REPO_NAME":"$tag" .
    else
        # single dockerfile for all environments - new
        docker build -q -t "$ECR_REPO_NAME":"$tag" .
    fi
    docker build -q --file ./envoy/Dockerfile -t "$ECR_REPO_NAME"_proxy:"$tag" ./envoy
fi

# Upload images to repository
if [[ $build_image = 'true' ]]; then
    print_section_info "Upload images to registry"
    aws ecr get-login-password | docker login --username AWS --password-stdin "$aws_ecr_repo_base_url"
    checkForAWSError $?
    docker tag "$ECR_REPO_NAME":"$tag" "$aws_ecr_repo_base_url"/"$ECR_REPO_NAME":"$tag"
    docker push "$aws_ecr_repo_base_url"/"$ECR_REPO_NAME":"$tag"
    checkForAWSError $?
    docker tag "$ECR_REPO_NAME"_proxy:"$tag" "$aws_ecr_repo_base_url"/"$ECR_REPO_NAME"_proxy:"$tag"
    docker push "$aws_ecr_repo_base_url"/"$ECR_REPO_NAME"_proxy:"$tag"
    checkForAWSError $? yes
fi

# Get ALB ARN
print_section_info "Get ALB ARN"
alb_prefix=$([[ "$deploy_type" == "App" ]] && echo "apps" || echo "services")
if [[ $PUBLIC_WS = 'true' ]]; then
    alb_name="alb-ceng-$alb_prefix-$deploy_context_lowercase-2"
else
    alb_name="alb-ceng-$alb_prefix-$deploy_context_lowercase"
fi
alb_arn=$(aws elbv2 describe-load-balancers --name "$alb_name" \
    --query 'LoadBalancers[*].LoadBalancerArn' --output text)
checkForAWSError $? yes
echo "ALB arn is $alb_arn"

# Get VPC Id
print_section_info "Get VPC Id"
vpc_id=$(aws ec2 describe-vpcs --filters "Name=tag:Environment,Values=$deploy_context" \
    --query 'Vpcs[*].VpcId' --output text)
checkForAWSError $? yes
if [[ -z "$vpc_id" ]]; then
    echo "Error: Cannot find vpc"
    exit 1
fi
echo "VPC Id is $vpc_id"

# Create target group
print_section_info "Create target group"
tg_name="${ECR_REPO_NAME//_/-}-$deploy_context_lowercase"
tg_arn=$(aws elbv2 describe-target-groups --name "$tg_name" \
    --query 'TargetGroups[*].TargetGroupArn' --output text)
if [[ -z "$tg_arn" ]]; then
    tg_arn=$(aws elbv2 create-target-group --name "$tg_name" --protocol "HTTPS" --port 443 \
        --health-check-path "/health" --target-type "ip" --vpc-id "$vpc_id" \
        --tags "Key=Environment,Value=$deploy_context" \
        --query 'TargetGroups[*].TargetGroupArn' --output text)
    checkForAWSError $? yes
    echo "Target group ($tg_name) created. Arn = $tg_arn"
else
    echo "Target group ($tg_name) already exists. Arn = $tg_arn"
fi

# Update target group properties
# deregistration_delay.timeout_seconds value must be less than stopTimeout value in task definition
print_section_info "Update target group properties"
value=$(aws elbv2 modify-target-group-attributes --target-group-arn "$tg_arn" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=100 \
    --query 'Attributes[?Key==`deregistration_delay.timeout_seconds`].Value' --output text)
checkForAWSError $? yes
echo "Target group ($tg_name) properties (deregistration_delay: $value) updated."

# Get HTTPS Listener ARN
print_section_info "Get HTTPS Listener ARN"
list_arn=$(aws elbv2 describe-listeners --load-balancer-arn "$alb_arn" \
    --query "Listeners[?Protocol=='HTTPS'].ListenerArn" --output text)
checkForAWSError $? yes
echo "Listener ARN: $list_arn"

# Create rule for component on ALB listener
print_section_info "Create rule for component on ALB listener"
jq_pattern="/$APP_WS_BASE_PATH/*"
rule_arn=$(aws elbv2 describe-rules --listener-arn "$list_arn" |
    jq -r --arg v "$jq_pattern" '.Rules[] | . as $parent | .Conditions[].PathPatternConfig[] | select(. | index($v)) | $parent.RuleArn // empty')
if [[ -z "$rule_arn" ]]; then
    echo "There are no existing rules for this component"
    export my_path=$APP_WS_BASE_PATH
    envsubst <$template_path/alb_listener_condition_pattern.template >$template_path/alb_listener_condition_pattern.json
    rule_cnt=$(aws elbv2 describe-rules --listener-arn "$list_arn" |
        jq -r '[.Rules[].Priority][0:-1] | map(.|tonumber) | max + 1')
    rule_arn=$(aws elbv2 create-rule --listener-arn "$list_arn" \
        --conditions file://$template_path/alb_listener_condition_pattern.json \
        --actions Type=forward,TargetGroupArn="$tg_arn" --priority "$rule_cnt" \
        --tags "Key=Environment,Value=$deploy_context" \
        --query 'Rules[*].RuleArn' --output text)
    checkForAWSError $? yes
    echo "Rule created for component. Arn: $rule_arn"
else
    echo "Rule exists. Arn: $rule_arn"
fi

# Get VPC private subnets
print_section_info "Get VPC private subnets"
vpc_private_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" |
    jq -r '[.Subnets[] | select (.MapPublicIpOnLaunch==false) | .SubnetId]' |
    jq -r '[.[]] | join(",")')
checkForAWSError $? yes
IFS=', ' read -r -a vpc_private_subnets <<<"$vpc_private_subnets"
echo "VPC Subnet Ids: $(
    IFS=$'|'
    echo "${vpc_private_subnets[*]}"
)"
vpc_private_subnet1=${vpc_private_subnets[0]}
vpc_private_subnet2=${vpc_private_subnets[1]}

# Get container security group id
print_section_info "Get container security group id"
container_sg="ecs-fargate-sg-ceng-container-$deploy_context_lowercase"
container_sg_id=$(aws ec2 describe-security-groups \
    --filter Name=vpc-id,Values="$vpc_id" Name=group-name,Values="$container_sg" \
    --query 'SecurityGroups[*].GroupId' --output text)
checkForAWSError $? yes
echo "Container security group id: $container_sg_id"

# Create log group if it does not exist
print_section_info "Create log group if it does not exist"
log_grp_name="/ecs/${ECR_REPO_NAME}_${deploy_context_lowercase}"
log_grp_exist=$(aws logs describe-log-groups --log-group-name-prefix "$log_grp_name" \
    --query 'length(logGroups[])')
if [[ "$log_grp_exist" != "1" ]]; then
    aws logs create-log-group --log-group-name "$log_grp_name" --tags "Key=Environment,Value=$deploy_context"
    checkForAWSError $? yes
    echo "Log group $log_grp_name created"
else
    echo "Log group $log_grp_name already exists"
fi

# Get CloudMap namespace id
print_section_info "Get CloudMap namespace id"
namespace="cluster.ceng.local.$deploy_context_lowercase"
namespace_id=$(aws servicediscovery list-namespaces \
    --query "Namespaces[?Name=='$namespace'].Id" --output text)
checkForAWSError $? yes
echo "Namespace id: $namespace_id"

# Create CloudMap service if it does not exist
print_section_info "Create CloudMap service if it does not exist"
sr_service_name="${ECR_REPO_NAME//_/-}"
sr_arn=$(aws servicediscovery list-services --filters "Name=NAMESPACE_ID,Values=$namespace_id" \
    --query "Services[?Name=='$sr_service_name'].Arn" --output text)
checkForAWSError $? yes
if [[ -z "$sr_arn" ]]; then
    sr_arn=$(aws servicediscovery create-service --name "$sr_service_name" \
        --dns-config "NamespaceId='$namespace_id',DnsRecords=[{Type='A',TTL='300'}]" \
        --health-check-custom-config FailureThreshold=1 \
        --tags "Key=Environment,Value=$deploy_context" --query 'Service.Arn' --output text)
    checkForAWSError $? yes
    echo "CloudMap service $sr_service_name created"
else
    echo "CloudMap service $sr_service_name already exists"
fi

# Get EFS volume id
print_section_info "Get EFS volume id"
fs_name="efs-ceng-$deploy_context_lowercase"
fs_id=$(aws efs describe-file-systems \
    --query "FileSystems[?Name=='$fs_name'].FileSystemId" --output text)
checkForAWSError $? yes
echo "File system id: $fs_id"

# Get envoy certificates accesspoint
print_section_info "Get envoy certificates accesspoint"
envoy_ssl_ap_id=$(aws efs describe-access-points --file-system-id "$fs_id" \
    --query "AccessPoints[?Name=='$ENVOY_SSL_EFS_ACCESSPOINT_NAME'].AccessPointId" --output text)
checkForAWSError $? yes
echo "Envoy SSL EFS AccessPoint Id: $envoy_ssl_ap_id"

# Get container logs accesspoint
print_section_info "Get container logs accesspoint"
cntrlogs_ap_id=$(aws efs describe-access-points --file-system-id "$fs_id" \
    --query "AccessPoints[?Name=='$CONTAINER_LOGS_EFS_ACCESSPOINT_NAME'].AccessPointId" --output text)
checkForAWSError $? yes
echo "Container logs EFS AccessPoint Id: $cntrlogs_ap_id"

# Get container storage accesspoint
print_section_info "Get container storage accesspoint"
cntrstrg_ap_id=$(aws efs describe-access-points --file-system-id "$fs_id" \
    --query "AccessPoints[?Name=='$CONTAINER_STORAGE_EFS_ACCESSPOINT_NAME'].AccessPointId" --output text)
checkForAWSError $? yes
echo "Container storage EFS AccessPoint Id: $cntrstrg_ap_id"

# Get ARN for Bastion secrets
print_section_info "Get arn for Bastion secrets"
bastion_secrets_arn=$(aws secretsmanager get-secret-value --secret-id "$deploy_context_uppercase"_BASTION_PUBKEYS \
    --query 'ARN' --output text)
checkForAWSError $? yes
echo "Bastion secrets Arn: $bastion_secrets_arn"

# Get ARN for service db secrets
if [[ $USES_DB != 'false' ]]; then
    print_section_info "Get arn for Service DB secrets"
    db_secret_name="$deploy_context_uppercase"_$(echo "$ECR_REPO_NAME" | tr '[:lower:]' '[:upper:]' | cut -d_ -f1)_WS_DB
    db_secret_arn=$(aws secretsmanager get-secret-value --secret-id "$db_secret_name" \
        --query 'ARN' --output text)
    # Below must match value of VARS_PREFIX in service env file
    var_prefix=$(echo "$ECR_REPO_NAME" | tr '[:lower:]' '[:upper:]' | cut -d_ -f1)WS
    db_host="$var_prefix"_DB_HOST
    db_user="$var_prefix"_DB_USERNAME
    db_pass="$var_prefix"_DB_PASSWORD
    db_schema="$var_prefix"_DB_DATABASE
    db_port="$var_prefix"_DB_PORT
    checkForAWSError $? yes
    echo "Service DB secrets Arn: $db_secret_arn"
fi

# Create task definition
print_section_info "Create task definition"
service_name=$ECR_REPO_NAME
service_env_file="$ECR_REPO_NAME.env"
s3b_name="ceng-appconfig-$deploy_context_lowercase"
export tag
export envoy_ssl_ap_id
export cntrlogs_ap_id
export cntrstrg_ap_id
export s3b_name
export service_env_file
export deploy_context
export deploy_context_lowercase
export log_grp_name
export service_name
export fs_id
export aws_ecr_repo_url_proxy="$aws_ecr_repo_base_url"/"$ECR_REPO_NAME"_proxy
export aws_ecr_repo_url_main="$aws_ecr_repo_base_url"/"$ECR_REPO_NAME"
export sr_service_name
export namespace
export bastion_secrets_arn
if [[ $USES_DB = 'false' ]]; then
    envsubst <$template_path/ecs_"$deploy_type_lowercase"_task_def."$deploy_context_lowercase".nodb.template >$template_path/ecs_"$deploy_type_lowercase"_task_def.json
else
    export db_secret_arn
    export db_host
    export db_user
    export db_pass
    export db_schema
    export db_port
    envsubst <$template_path/ecs_"$deploy_type_lowercase"_task_def."$deploy_context_lowercase".template >$template_path/ecs_"$deploy_type_lowercase"_task_def.json
fi
taskdef_rev=$(aws ecs register-task-definition \
    --cli-input-json file://$template_path/ecs_"$deploy_type_lowercase"_task_def.json \
    --query 'taskDefinition.revision' --output text)
checkForAWSError $? yes
echo "Created revision $taskdef_rev for $service_name"

# Create/Update service in ECS cluster
print_section_info "Create/Update service in ECS cluser"
ecs_service_name=$sr_service_name
cluster_name="ecs-fargate-cluster-ceng-$deploy_context_lowercase"
service_arn=$(aws ecs describe-services --cluster "$cluster_name" --services "$ecs_service_name" \
    --query "services[?status=='ACTIVE'].serviceArn" --output text)
checkForAWSError $?
if [[ -z "$service_arn" ]]; then
    # create
    export ecs_service_name
    export cluster_name
    export service_name
    export taskdef_rev
    export tg_arn
    export container_sg_id
    export deploy_context
    export vpc_private_subnet1
    export vpc_private_subnet2
    export sr_arn
    envsubst <$template_path/ecs_"$deploy_type_lowercase"_service_def."$deploy_context_lowercase".template >$template_path/ecs_"$deploy_type_lowercase"_service_def.json
    service_arn=$(aws ecs create-service --cli-input-json file://$template_path/ecs_"$deploy_type_lowercase"_service_def.json \
        --query 'service.serviceArn' --output text)
    checkForAWSError $? yes yes
    echo "ECS Service $ecs_service_name created. Arn: $service_arn"
else
    # update
    service_arn=$(aws ecs update-service --service "$ecs_service_name" --task-definition "$service_name:$taskdef_rev" \
        --cluster "$cluster_name" --force-new-deployment \
        --query 'service.serviceArn' --output text)
    checkForAWSError $? yes yes
    echo "ECS Service $ecs_service_name updated. Arn: $service_arn"
fi

# Specify retention period for ECS task log group
print_section_info "Specify retention period for ECS task log group"
if [[ $deploy_context_lowercase = 'staging' ]]; then
    retention=$log_retention_staging
else
    retention=$log_retention_production
fi
aws logs put-retention-policy --log-group-name "$log_grp_name" --retention-in-days "$retention"
echo "Retention period updated for service log group in cloudwatch."

# Create/update scaling target setup - Production only
if [[ $deploy_context = 'Production' ]]; then
    print_section_info "Create/update scaling target setup - Production only"
    resource_id="service/$cluster_name/$ecs_service_name"
    aws application-autoscaling register-scalable-target --service-namespace ecs \
        --scalable-dimension ecs:service:DesiredCount --resource-id "$resource_id" \
        --min-capacity "$ecs_min_capacity" --max-capacity "$ecs_max_capacity"
    checkForAWSError $?
    echo "ECS scaling target setup. ResourceId: $resource_id."
fi

# Create/update cpu scaling policy - Production only
if [[ $deploy_context = 'Production' ]]; then
    print_section_info "Create/update CPU scaling policy - Production only"
    cpu_policy_arn=$(aws application-autoscaling put-scaling-policy --service-namespace ecs \
        --scalable-dimension ecs:service:DesiredCount --resource-id "$resource_id" \
        --policy-name "ecs-scaling-cpu-policy-$ecs_service_name" --policy-type TargetTrackingScaling \
        --target-tracking-scaling-policy-configuration "file://$policy_path/ecs_scaling_cpu_policy.$deploy_context_lowercase.json" \
        --query 'PolicyARN' --output text)
    checkForAWSError $?
    echo "CPU policy created. Arn: $cpu_policy_arn"
fi

# Create/update ram scaling policy - Production only
if [[ $deploy_context = 'Production' ]]; then
    print_section_info "Create/update RAM scaling policy - Production only"
    ram_policy_arn=$(aws application-autoscaling put-scaling-policy --service-namespace ecs \
        --scalable-dimension ecs:service:DesiredCount --resource-id "$resource_id" \
        --policy-name "ecs-scaling-ram-policy-$ecs_service_name" --policy-type TargetTrackingScaling \
        --target-tracking-scaling-policy-configuration "file://$policy_path/ecs_scaling_ram_policy.$deploy_context_lowercase.json" \
        --query 'PolicyARN' --output text)
    checkForAWSError $?
    echo "RAM policy created. Arn: $ram_policy_arn"
    echo "Deploy completed."
fi

# test ssh with 2 tasks on 1 service
