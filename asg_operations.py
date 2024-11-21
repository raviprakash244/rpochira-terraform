import boto3
import json
import logging
from collections import defaultdict


# Initialize boto3 clients for EC2 and Auto Scaling
ec2_client = boto3.client('ec2')
autoscaling_client = boto3.client('autoscaling')

# Setup logging for debugging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Lambda handler
def lambda_handler(event, context):
    logger.info(f"Event: {json.dumps(event)}")
    
    # Get the details of the Auto Scaling lifecycle hook event
    lifecycle_event_Records = event.get('Records', {})
    logger.info(f"Records: {lifecycle_event_Records}")
    if len(lifecycle_event_Records) != 0:
        lifecycle_event_string = lifecycle_event_Records[0].get("Sns", {}).get("Message")
        lifecycle_event = json.loads(lifecycle_event_string)
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

    if not auto_scaling_group_name:
        return {
            "statusCode": 400,
            "body": "Missing AutoScalingGroupName in the event."
        }

    # if lifecycle_event == "autoscaling:TEST_NOTIFICATION":
    return handle__new_provision(event)

def handle__new_provision(event):

    # Get the details of the Auto Scaling lifecycle hook event
    lifecycle_event_Records = event.get('Records', {})    
    lifecycle_event_string = lifecycle_event_Records[0].get("Sns", {}).get("Message")
    lifecycle_event = json.loads(lifecycle_event_string)

    lifecycle_action_token = lifecycle_event.get('LifecycleActionToken')
    auto_scaling_group_name = lifecycle_event.get('AutoScalingGroupName')
    instance_id = lifecycle_event.get('EC2InstanceId')
    lifecycle_transition = lifecycle_event.get('LifecycleTransition')
    lifecycle_event = lifecycle_event.get('Event')

    logger.info("New cluster provisioning request started. ")
    logger.info(f"Autoscaling group name: {auto_scaling_group_name}")
    interfaces = get_networkinterfaces(auto_scaling_group_name)
    logger.info(f"Available Intarfaces: {interfaces}")
    logger.info("Fetching the information of all EC2 instances created as part of Autoscaling group: {AutoScalingGroupName}")
    instance_details = get_instances_in_asg(auto_scaling_group_name)
    if not instance_details:
        return {
            "statusCode": 200,
            "body": f"No instances found in Auto Scaling Group to be handled: {auto_scaling_group_name}"
        }
    logger.info(f"Instance details are below: {instance_details}")
    ec2_subnet_mapping = map_ec2_subnet(interfaces, instance_details)
    logger.info(f"Mapping of EC2 & Subnet: {ec2_subnet_mapping}")

    #Get the details of EBS volume.
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
                }
            ]

            tags_others = [
                {
                    'Key': 'Instance',
                    'Value': ec2_id
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
        
    tags = [
        {
            'Key': 'SubnetAttachStatus',
            'Value': 'Attached'
        },
        {
            'Key': 'Status',
            'Value': 'in-use'
        }
    ]            

    try:
        for item in ec2_subnet_mapping:
            ec2_id = item.get("InstanceId")
            logger.info(f"Adding final EC2 tags {tags}")
            final_tag_ec2s(ec2_id, tags)
            logger.info(f"Successfully added final EC2 tags.")
    except Exception as e:
        return {
                "statusCode": 400,
                "body": e
            }

    return {
        "statusCode": 200,
        "body": "Successfully attached all network interfaces to respective EC2 instances.  "
    }


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
                'Name': 'tag:' + 'AutoscaleGroup',  
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
        # Basic ENI information
        eni_id = eni['NetworkInterfaceId']
        subnet_id = eni['SubnetId']
        vpc_id = eni['VpcId']
        status = eni['Status']
        az = eni['AvailabilityZone']
        


        # If the ENI is attached, retrieve the instance ID and private IPs
        attachment_details = None
        private_ips = []
        if 'Attachment' in eni:
            attachment_details = eni['Attachment']
            instance_id = attachment_details['InstanceId']
            private_ips = [ip['PrivateIpAddress'] for ip in eni.get('PrivateIpAddresses', [])]
        else:
            instance_id = None  # If not attached
            private_ips = [ip['PrivateIpAddress'] for ip in eni.get('PrivateIpAddresses', [])]
        
        # Prepare the result
        eni_details.append({
            'eni_id': eni_id,
            'subnet_id': subnet_id,
            'vpc_id': vpc_id,
            'status': status,
            'availability_zone': az,
            'instance_id': instance_id,
            'private_ips': private_ips
        })
    
    # Return the collected ENI details
    return eni_details


    
def get_instances_in_asg(asg_name):
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
    logger.info(f"Received tags: {tags}")
    logger.info(f"Received filter: {filter}")
    tag_list = []
    tag = dict()
    for item in tags:
        tag_name = item.get("Key")
        tag_value = item.get("Value")
        tag[tag_name] = tag_value
        tag_list.append(tag)
        
    logger.info(f"Key Value pair of list of Tags: {tag_list}")
    
    for item in tag_list:
        keys = list(item.keys())
        search_key = filter.get("Name")
        search_value = filter.get("Value")
        logger.info(f"All tag keys: {keys}")
        
        logger.info(f"Search key: {search_key} and search value: {search_value}")
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
        if eni["status"] == "available":  # Only include available ENIs
            subnet_to_eni_map[eni["subnet_id"]].append(eni)

    # Distribute ENIs to EC2 instances
    ec2_eni_mapping = []

    for ec2 in ec2_data:
        subnet_id = ec2["SubnetId"]
        if subnet_id in subnet_to_eni_map and subnet_to_eni_map[subnet_id]:
            # Assign the first available ENI
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
    from collections import defaultdict
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

# def final_tag_ec2s(instance_id, tags):
#     try:
#         response = ec2_client.create_tags(
#             Resources=[instance_id],
#             Tags=tags
#          )
        
#         return response

#     except Exception as e:
#         raise Exception(f"Exception during tagging. {tags}")

def attach_ebs_volumes_to_ec2(instance_id, volume_id):
    # instance_id = ec2_instance.get("InstanceId")
    # volume_id = ec2_instance.get("AssignedVolumeId")
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
        
