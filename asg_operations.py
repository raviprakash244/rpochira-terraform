import boto3
import json
import logging
from collections import defaultdict
import time
import random

ec2_client = boto3.client('ec2')
autoscaling_client = boto3.client('autoscaling')

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    logger.info(f"Event: {json.dumps(event)}")
    
    lifecycle_event_Records = event.get('Records', {})
    logger.info(f"Records: {lifecycle_event_Records}")
    if len(lifecycle_event_Records) != 0:
        lifecycle_event_string = lifecycle_event_Records[0].get("Sns", {}).get("Message")
        lifecycle_event = json.loads(lifecycle_event_string)
        lifecycle_event_copy = json.loads(lifecycle_event_string)
        
    else:
         return {
            "statusCode": 400,
            "body": "No event records found."
        } 
    
    logger.info(f"Message: {lifecycle_event}")
    lifecycle_action_token = lifecycle_event.get('LifecycleActionToken')
    auto_scaling_group_name = lifecycle_event.get('AutoScalingGroupName')
    instance_id = lifecycle_event.get('EC2InstanceId')
    lifecycle_transition = lifecycle_event.get('LifecycleTransition')
    lifecycle_event = lifecycle_event.get('Event')
    lifecycle_hook_name = lifecycle_event_copy.get('LifecycleHookName')


    if not auto_scaling_group_name:
        return {
            "statusCode": 400,
            "body": "Missing AutoScalingGroupName in the event."
        }

    if lifecycle_event == "autoscaling:TEST_NOTIFICATION" and not lifecycle_transition:
        return handle__new_provision(event)
    else:
        return handle_autoscale(auto_scaling_group_name, instance_id, event)


def complete_lifecycle_action(asg_name, lifecycle_hook_name, lifecycle_action_token, result="CONTINUE"):
    autoscaling_client = boto3.client('autoscaling')

    try:
        response = autoscaling_client.complete_lifecycle_action(
            AutoScalingGroupName=asg_name,
            LifecycleHookName=lifecycle_hook_name,
            LifecycleActionToken=lifecycle_action_token,
            LifecycleActionResult=result
        )
        print("Lifecycle action completed successfully:", response)
    except Exception as e:
        print("Error completing lifecycle action:", str(e))



def handle_autoscale(auto_scaling_group_name, instance_id, event):
    lifecycle_event_Records = event.get('Records', {})    
    lifecycle_event_string = lifecycle_event_Records[0].get("Sns", {}).get("Message")
    lifecycle_event = json.loads(lifecycle_event_string)
    lifecycle_event_copy = json.loads(lifecycle_event_string)

    lifecycle_action_token = lifecycle_event.get('LifecycleActionToken')
    auto_scaling_group_name = lifecycle_event.get('AutoScalingGroupName')
    instance_id = lifecycle_event.get('EC2InstanceId')
    lifecycle_transition = lifecycle_event.get('LifecycleTransition')
    lifecycle_event = lifecycle_event.get('Event')
    lifecycle_hook_name = lifecycle_event_copy.get('LifecycleHookName')

    logger.info(f"Fetching the information of all EC2 instances created as part of Autoscaling group: {auto_scaling_group_name}")
    instance_details = get_instances_in_asg(auto_scaling_group_name, instance_id)
    instance_details = instance_details[0]
    subnet_id = instance_details.get("subnet_id")
    subnets = get_subnets(auto_scaling_group_name, subnet_id)

    if not subnets or len(subnets) == 0:
        logger.info("This seems to be ASG operation for instance refresh. This gets handled during termination of other instance.")
        if lifecycle_transition == "autoscaling:EC2_INSTANCE_LAUNCHING":
            complete_lifecycle_action(auto_scaling_group_name, lifecycle_hook_name, lifecycle_action_token)
        else:
            handle_instance_termination(auto_scaling_group_name, instance_id, event)
    else:
        handle__new_provision(event)


def handle_instance_termination(auto_scaling_group_name, instance_id, event):
    tags = read_asg_tags(auto_scaling_group_name)
    instance_resources = get_instance_components(instance_id, tags)

    lifecycle_event_Records = event.get('Records', {})    
    lifecycle_event_string = lifecycle_event_Records[0].get("Sns", {}).get("Message")
    lifecycle_event = json.loads(lifecycle_event_string)
    lifecycle_event_copy = json.loads(lifecycle_event_string)

    lifecycle_action_token = lifecycle_event.get('LifecycleActionToken')
    auto_scaling_group_name = lifecycle_event.get('AutoScalingGroupName')
    instance_id = lifecycle_event.get('EC2InstanceId')
    lifecycle_transition = lifecycle_event.get('LifecycleTransition')
    lifecycle_event = lifecycle_event.get('Event')
    lifecycle_hook_name = lifecycle_event_copy.get('LifecycleHookName')

    if instance_resources.get("ebs_id"):
        detach_ebs_volume(instance_id, instance_resources.get("ebs_id"))
    
    if instance_resources.get("eni_id"):
        detach_eni(instance_id, instance_resources.get("eni_id"))

    tags_others = [
        {
            'Key': 'Instance',
            'Value': ec2_id
        },
        {
            'Key': 'Status',
            'Value': 'available'
        }
    ]

    tag_eni(eni_id, tags_others)
    tag_ebs(volume_id, tags_others)
    
    response = handle__new_provision(event)
    complete_lifecycle_action(auto_scaling_group_name, lifecycle_hook_name, lifecycle_action_token)

    return response

def detach_ebs_volume(instance_id, volume_id):
    ec2_client = boto3.client('ec2')
    try:
        response = ec2_client.detach_volume(
            VolumeId=volume_id,
            InstanceId=instance_id,
            Force=force
        )

        return response
    except Exception as e:
        raise Exception(f"Failed to detach EBS volume {volume_id} from instance {instance_id}. {e}")

def detach_eni(instance_id, eni_id):

    attachment_id = get_attachment_id_from_eni(eni_id)
    try:
        response = ec2_client.detach_network_interface(
                    AttachmentId=attachment_id,
                    Force=force
                )
        return response
    except Exception as e:
        raise Exception(f"Failed to detach ENI {eni_id} from instance {instance_id}. {e}")

def get_attachment_id_from_eni(eni_id):
    ec2_client = boto3.client('ec2')

    try:
        response = ec2_client.describe_network_interfaces(
            NetworkInterfaceIds=[eni_id]
        ) 

        network_interface = response["NetworkInterfaces"][0]
        attachment = network_interface.get("Attachment")

        if attachment:
            attachment_id = attachment.get("AttachmentId")
            return attachment_id
        else:
            logger.info(f"No Attachment id found. ENI {eni_id} is not attached to any instance.")
            return None
    except Exception as e:
        raise Exception(f"Failed to read ENI for attachment id {e}")

def read_asg_tags(asg_name):
    client = boto3.client('autoscaling')
    try:
        response = client.describe_auto_scaling_groups(
                AutoScalingGroupNames=[asg_name])
        asg_details = response.get('AutoScalingGroups', [])
        if not asg_details:
            raise Exception(f"No Auto Scaling Group found with the name '{asg_name}'")
        tags = asg_details[0].get('Tags', [])
        return tags 
    except Exception as e:
        raise Exception(f"Error in reading tags of Autoscaling group. {e}")

def get_instance_components(instance, tags):
    resources = {
        "subnet_id": None,
        "eni_id": None,
        "ebs_id": None
    }

    for tag in tags:
        key = tag.get("Key")
        value = tag.get("Value")
        
        if key == f"subnet_{instance_name}":
            resources["subnet_id"] = value
        elif key == f"eni_{instance_name}":
            resources["eni_id"] = value
        elif key == f"ebs_{instance_name}":
            resources["ebs_id"] = value

    return resources


def get_subnets(auto_scaling_group_name, subnet_id):
    networks = get_networkinterfaces(auto_scaling_group_name)
    if not networks or len(networks) == 0:
        return []
    else:
        return [eni for eni in networks if eni.get("subnet_id") == subnet_id]

def lock_asg(asg_name):
    initial_tag = [{ 
        "Key" : "asg_lock",
        "Value": "lock"
    }]

    try:
        response = tag_asg(asg_name, initial_tag)
        return True
    except Exception as e:
        raise Exception(f"Error unlocking autoscaling group.")

def unlock_asg(asg_name):
    initial_tag = [{ 
        "Key" : "asg_lock",
        "Value": "free"
    }]

    try:
        response = tag_asg(asg_name, initial_tag)
        return True
    except Exception as e:
        raise Exception(f"Error locking autoscaling group.")

def asg_status(asg_name):
    tags = read_asg_tags(asg_name)
    logger.info(f"Current ASG tags: {tags}")
    asg_status = "free"
    for tag in tags:
        if tag["Key"] == "asg_lock":
            asg_status = tag.get("Value")
        break

    logger.info(f"Current asg status: {asg_status}")
    return asg_status


def handle__new_provision(event):

    lifecycle_event_Records = event.get('Records', {})    
    lifecycle_event_string = lifecycle_event_Records[0].get("Sns", {}).get("Message")
    lifecycle_event = json.loads(lifecycle_event_string)
    lifecycle_event_copy = json.loads(lifecycle_event_string)

    lifecycle_action_token = lifecycle_event.get('LifecycleActionToken')
    auto_scaling_group_name = lifecycle_event.get('AutoScalingGroupName')
    instance_id = lifecycle_event.get('EC2InstanceId')
    lifecycle_transition = lifecycle_event.get('LifecycleTransition')
    lifecycle_event = lifecycle_event.get('Event')
    lifecycle_hook_name = lifecycle_event_copy.get('LifecycleHookName')
    fraction = random.uniform(0, 10)
    time.sleep(fraction)

    while True:
        fraction = random.uniform(0, 10)
        asg_lock_status = asg_status(auto_scaling_group_name)
        if asg_lock_status == "free":
            lock_asg(auto_scaling_group_name)
            break
        else:
            logger.info(f"Autoscaling group currently {auto_scaling_group_name} is currently locked. ")
            time.sleep(2)

    
    time.sleep(30)
    if not lifecycle_transition:
        logger.info("New cluster provisioning request started. ")
    else:
        logger.info("New Autoscale event processing started. ")

    logger.info(f"Autoscaling group name: {auto_scaling_group_name}")
    interfaces = get_networkinterfaces(auto_scaling_group_name)
    logger.info(f"Available Intarfaces: {interfaces}")
    logger.info(f"Fetching the information of all EC2 instances created as part of Autoscaling group: {auto_scaling_group_name}")

    instance_details = get_instances_in_asg(auto_scaling_group_name, instance_id)
    if not instance_details:
        return {
            "statusCode": 200,
            "body": f"No instances found in Auto Scaling Group to be handled: {auto_scaling_group_name}"
        }
    logger.info(f"Instance details are below: {instance_details}")
    ec2_subnet_mapping = map_ec2_subnet(interfaces, instance_details)
    logger.info(f"Mapping of EC2 & Subnet: {ec2_subnet_mapping}")

    ebs_data = get_ebs_volumes_with_tag("AsgName", auto_scaling_group_name)
    logger.info(f"Available EBS volumes: {ebs_data}")

    ec2_subnet_mapping = distribute_ebs_volumes_to_ec2(ec2_subnet_mapping, ebs_data)
    logger.info(f"Final Data with EBS volume mapping: {ec2_subnet_mapping}")

    for item in ec2_subnet_mapping:
        try:
            eni_id = item.get("AssignedENI")
            ec2_id = item.get("InstanceId")
            subnet_id = item.get("SubnetId")
            volume_id = item.get("AssignedVolumeId")
            
            logger.info(f"Attaching eni id {eni_id} to {ec2_id}")
            
            response = ec2_client.attach_network_interface(
                    NetworkInterfaceId=eni_id,
                    InstanceId=ec2_id,
                    DeviceIndex=1
                )
            logger.info(f"Successfully attached {eni_id} to {ec2_id}.")

            response = attach_ebs_volumes_to_ec2(ec2_id, volume_id)

            tags = [
                {
                    'Key': 'Subnet',
                    'Value': subnet_id
                },
                {
                    'Key': 'NetworkInterfaceId',
                    'Value': eni_id
                },
                {
                    'Key': 'Status',
                    'Value': 'in-use'
                },
                {
                    'Key': 'AsgName',
                    'Value': auto_scaling_group_name
                },
                {
                    'Key': 'SubnetAttachStatus',
                    'Value': 'Attached'
                },
            ]

            tags_others = [
                {
                    'Key': 'Instance',
                    'Value': ec2_id
                },
                {
                    'Key': 'AsgName',
                    'Value': auto_scaling_group_name
                },
                {
                    'Key': 'Status',
                    'Value': 'in-use'
                }
            ]

            tag_eni(eni_id, tags_others)
            tag_ebs(volume_id, tags_others)

            logger.info(f"Adding network interface tags {tags}")

            final_tag_ec2s(ec2_id, tags)

            logger.info(f"Successfully added network interface tags. ")

        except Exception as e:
            logger.error(f"Error in attaching interface {eni_id} to {ec2_id}. {e}")
            return {
                    "statusCode": 400,
                    "body": f"Error in attaching interface {eni_id} to {ec2_id}. {e}"
                }
    try:
        response = add_final_tags(auto_scaling_group_name, ec2_subnet_mapping)
    except Exception as e:
        return {
                "statusCode": 400,
                "body": f"Failed to add final tags to autoscaling group. {e}"
            }
    
    # if lifecycle_hook_name and auto_scaling_group_name and lifecycle_action_token:
    #     complete_lifecycle_action(auto_scaling_group_name, lifecycle_hook_name, lifecycle_action_token)
    
    unlock_asg(auto_scaling_group_name)
    return {
        "statusCode": 200,
        "body": "Successfully attached all devices."
     }

def add_final_tags(auto_scaling_group_name, ec2_subnet_mapping):
    logger.info("Adding final tags to Auto scaling group.")
    asg_tags = []
    
    for item in ec2_subnet_mapping:
        instance_id = item.get("InstanceId")
        subnet_id = item.get("SubnetId")
        eni_id = item.get("AssignedENI")
        ebs_id = item.get("AssignedVolumeId")
        
        asg_tags.append ({
                'Key': f'subnet_{instance_id}', 
                'Value': subnet_id
            })

        asg_tags.append ({
                'Key': f'eni_{instance_id}', 
                'Value': eni_id
            })

        asg_tags.append ({
                'Key': f'ebs_{instance_id}', 
                'Value': eni_id
            })
        
        asg_tags.append(
            { 
            "Key" : "asg_lock",
            "Value": "unlocked"
        })
        
    try:
        response = tag_asg(auto_scaling_group_name, asg_tags)
        return response
    except Exception as e:
        raise Exception(f"Error  in tagging Autoscaling group with final tags {e}")

def tag_eni(id, tags):
    try:
        response = ec2_client.create_tags(Resources=[id], Tags=tags)
        logger.info(f"Successfully tagged. ENI {id} with tags {tags}")
        return response
    except Exception as e:
        logger.error(f"Error in tagging ENI with id {id} with tags {tags}")
        raise Exception(f"Error in tagging ENI with id {id} with tags {tags}")

def tag_ebs(id, tags):
    try:
        response = ec2_client.create_tags(Resources=[id], Tags=tags)
        logger.info(f"Successfully tagged. EBS {id} with tags {tags}")
        return response
    except Exception as e:
        logger.error(f"Error in tagging EBS with id {id} with tags {tags}")
        raise Exception(f"Error in tagging EBS with id {id} with tags {tags}")

def final_tag_ec2s(instance_id, tags):
    try:
        response = ec2_client.create_tags(
            Resources=[instance_id],
            Tags=tags
         )
        
        return response

    except Exception as e:
        raise Exception(f"Exception during tagging. {tags}")


def get_networkinterfaces(ags_name):
    
    filters = [
            {
                'Name': 'tag:AutoscaleGroup',  
                'Values': [ags_name]      
            },
            {
                'Name': 'status',         
                'Values': ["available"]        
            }
        ]    
    logger.info(f"filters: {filters}")
    response = ec2_client.describe_network_interfaces(Filters=filters)
    logger.info(f"All interfaces:{response}")
    network_interfaces = response['NetworkInterfaces']

    eni_details = []
    for eni in network_interfaces:
        eni_id = eni['NetworkInterfaceId']
        subnet_id = eni['SubnetId']
        vpc_id = eni['VpcId']
        status = eni['Status']
        az = eni['AvailabilityZone']
        
        attachment_details = None
        private_ips = []
        if 'Attachment' in eni:
            attachment_details = eni['Attachment']
            instance_id = attachment_details['InstanceId']
            private_ips = [ip['PrivateIpAddress'] for ip in eni.get('PrivateIpAddresses', [])]
        else:
            instance_id = None  
            private_ips = [ip['PrivateIpAddress'] for ip in eni.get('PrivateIpAddresses', [])]
        
        eni_details.append({
            'eni_id': eni_id,
            'subnet_id': subnet_id,
            'vpc_id': vpc_id,
            'status': status,
            'availability_zone': az,
            'instance_id': instance_id,
            'private_ips': private_ips
        })
    
    return eni_details


    
def get_instances_in_asg(asg_name, instance_identifier):

    instance_ids = []

    if instance_identifier:
        instance_id.append(instance_identifier)
    else:
        try:
            response = autoscaling_client.describe_auto_scaling_groups(
                AutoScalingGroupNames=[asg_name]
            )
            logger.info(f"Response of Autoscaling group: {response}")
            instance_ids = []
            for asg in response.get("AutoScalingGroups", []):
                for instance in asg.get("Instances", []):
                    if instance.get("LifecycleState") == "InService":
                        instance_ids.append(instance["InstanceId"])
        
            logger.info(f"Instance ids are: {instance_ids}")
            instance_details = get_instance_details(instance_ids)

            return instance_details
        except Exception as e:
            print(f"Error fetching instances for ASG {asg_name}: {e}")
            return []

def filter_tags(tags, filter):
    tag_list = []
    tag = dict()
    for item in tags:
        tag_name = item.get("Key")
        tag_value = item.get("Value")
        tag[tag_name] = tag_value
        tag_list.append(tag)
            
    for item in tag_list:
        keys = list(item.keys())
        search_key = filter.get("Name")
        search_value = filter.get("Value")

        if search_key in keys:
            if item.get(search_key) == search_value:
                return True
            else:
                return False
        else:
            return False
                
        
def get_instance_details(instance_ids):
    try:
        filter= {
                'Name': 'Status',
                'Value': 'available'
            }
        response = ec2_client.describe_instances(
            InstanceIds=instance_ids )
            
        logger.info(f"Response of read instance: {response}")
        instance_details = []
        for reservation in response.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                tags = instance.get("Tags")
                logger.info(f"Available tags of EC2: {tags}")
                if not filter_tags(tags, filter):
                    continue
                else:
                    network_interfaces = []
                    for eni in instance.get("NetworkInterfaces", []):
                        network_interfaces.append({
                            "NetworkInterfaceId": eni["NetworkInterfaceId"],
                            "PrivateIpAddress": eni.get("PrivateIpAddress"),
                            "Status": eni.get("Status")
                        })
                    instance_details.append({
                        "InstanceId": instance["InstanceId"],
                        "SubnetId": instance["SubnetId"],
                        "AvailabilityZone": instance["Placement"]["AvailabilityZone"],
                        "NetworkInterfaces": network_interfaces
                    })
        return instance_details
    except Exception as e:
        print(f"Error fetching details for instances: {e}")
        return []



def map_ec2_subnet(subnet_data, ec2_data):

    subnet_to_eni_map = defaultdict(list)
    for eni in subnet_data:
        if eni["status"] == "available":  
            subnet_to_eni_map[eni["subnet_id"]].append(eni)

    ec2_eni_mapping = []

    for ec2 in ec2_data:
        subnet_id = ec2["SubnetId"]
        if subnet_id in subnet_to_eni_map and subnet_to_eni_map[subnet_id]:
            assigned_eni = subnet_to_eni_map[subnet_id].pop(0)
            ec2_eni_mapping.append({
                "InstanceId": ec2["InstanceId"],
                "SubnetId": subnet_id,
                "AssignedENI": assigned_eni["eni_id"],
                "availability_zone": ec2["AvailabilityZone"]
            })
        else:
            ec2_eni_mapping.append({
                "InstanceId": ec2["InstanceId"],
                "SubnetId": subnet_id,
                "AssignedENI": None,
                "availability_zone": ec2["AvailabilityZone"]
            })

    
    return ec2_eni_mapping

def get_ebs_volumes_with_tag(tag_key, tag_value):
    try:
        response = ec2_client.describe_volumes(
            Filters=[
                {
                    'Name': 'tag:' + tag_key,
                    'Values': [tag_value]
                },
                {
                    'Name': 'tag:Status',
                    'Values': ['available']
                }
            ]
        )
        volumes = response.get('Volumes', [])
        
        volume_details = []
        for volume in volumes:
            volume_id = volume.get('VolumeId')
            availability_zone = volume.get('AvailabilityZone')
            
            volume_details.append({
                'VolumeId': volume_id,
                'AvailabilityZone': availability_zone
            })
        
        return volume_details
    
    except Exception as e:
        logger.error(f"Error fetching EBS volumes with tag {tag_key}:{tag_value}. {e}")
        return []

def distribute_ebs_volumes_to_ec2(ec2_subnet_mapping, ebs_volumes):
    volumes_by_az = defaultdict(list)
    for volume in ebs_volumes:
        az = volume.get('AvailabilityZone')
        volume_id = volume.get('VolumeId')
        volumes_by_az[az].append(volume_id)
    
    for ec2_instance in ec2_subnet_mapping:
        instance_id = ec2_instance.get("InstanceId")
        az = ec2_instance.get("availability_zone")
        
        if az in volumes_by_az and volumes_by_az[az]:
            volume_id = volumes_by_az[az].pop(0)  
            ec2_instance["AssignedVolumeId"] = volume_id 
            logger.info(f"Successfully assigned EBS volume {volume_id} to EC2 instance {instance_id} in AZ {az}.")
        else:
            ec2_instance["AssignedVolumeId"] = None  
            logger.warning(f"No available EBS volume for EC2 instance {instance_id} in AZ {az}.")
    
    return ec2_subnet_mapping

def attach_ebs_volumes_to_ec2(instance_id, volume_id):
    try:
        logger.info(f"Attaching volume {volume_id} to instance {instance_id}.")
        response = ec2_client.attach_volume(
            VolumeId=volume_id,
            InstanceId=instance_id,
            Device='/dev/xvdf'
        )
        logger.info(f"Successfully attached volume {volume_id} to instance {instance_id}.")

        return response
    except Exception as e:
        raise Exception(f"Failed to attach volume {volume_id} to instance {instance_id}. Error: {e}")
        
def tag_asg(asg_name, tags):
    logger.info(f"adding tags {tags} to {asg_name}")
    autoscaling_client = boto3.client('autoscaling')
    formatted_tags = [
        {
            'ResourceId': asg_name,
            'ResourceType': 'auto-scaling-group',
            'Key': tag['Key'],
            'Value': tag['Value'],
            'PropagateAtLaunch': tag.get('PropagateAtLaunch', True)
        }
        for tag in tags
     ]
    
    try:
        autoscaling_client.create_or_update_tags(Tags=formatted_tags)
        print(f"Tags successfully added to Auto Scaling group {asg_name}.")
    except Exception as e:
        raise Exception(f"Error adding tags to Auto Scaling group {asg_name}. {e}")