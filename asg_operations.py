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

    if lifecycle_event == "autoscaling:TEST_NOTIFICATION":
        logger.info("New cluster provisioning request started. ")
        logger.info(f"Autoscaling group name: {auto_scaling_group_name}")
        interfaces = get_networkinterfaces(auto_scaling_group_name)
        logger.info(f"Available Intarfaces: {interfaces}")
        logger.info("Creating VM mapping as per the subnets.")
        logger.info("Fetching the information of all EC2 instances created as part of Autoscaling group: {AutoScalingGroupName}")
        instance_ids = get_instances_in_asg(auto_scaling_group_name)
        if not instance_ids:
            return {
                "statusCode": 200,
                "body": f"No instances found in Auto Scaling Group: {auto_scaling_group_name}"
            }
        # Get detailed information about the instances
        instance_details = get_instance_details(instance_ids)
        logger.info(f"Instance details are below: {instance_details}")
        ec2_subnet_mapping = map_ec2_subnet(interfaces, instance_details)
        logger.info(f"Mapping of EC2 & Subnet: {ec2_subnet_mapping}")

        for item in ec2_subnet_mapping:
            try:
                eni_id = item.get("AssignedENI")
                ec2_id = item.get("InstanceId")

                response = ec2_client.attach_network_interface(
                        NetworkInterfaceId=item.get("AssignedENI"),
                        InstanceId=item.get("InstanceId"),
                        DeviceIndex=1
                    )
                logger.info(f"{eni_id} has been attached to {ec2_id} successfully.")
            except Exception as e:
                logger.error(f"Error in attaching interface {eni_id} to {ec2_id}. {e}")

        return {
            "statusCode": 200,
            "body": json.dumps(ec2_subnet_mapping)
        }

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
        instance_ids = []
        for asg in response.get("AutoScalingGroups", []):
            for instance in asg.get("Instances", []):
                # Only include instances that are InService
                if instance.get("LifecycleState") == "InService":
                    instance_ids.append(instance["InstanceId"])
        return instance_ids
    except Exception as e:
        print(f"Error fetching instances for ASG {asg_name}: {e}")
        return []

def get_instance_details(instance_ids):
    """Retrieve detailed information about the specified EC2 instances."""
    try:
        response = ec2_client.describe_instances(
            InstanceIds=instance_ids
        )
        instance_details = []
        for reservation in response.get("Reservations", []):
            for instance in reservation.get("Instances", []):
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
                "AssignedENI": assigned_eni["eni_id"]
            })
        else:
            ec2_eni_mapping.append({
                "InstanceId": ec2["InstanceId"],
                "SubnetId": subnet_id,
                "AssignedENI": None  # No available ENI
            })

    
    return ec2_eni_mapping


# def subnet_enis(eni_data):
#     subnet_to_enis = {}
#     for eni in eni_data:
#         subnet_id = eni["subnet_id"]
#         eni_id = eni["eni_id"]
        
#         # Append ENI ID to the corresponding subnet
#         if subnet_id not in subnet_to_enis:
#             subnet_to_enis[subnet_id] = []
#         subnet_to_enis[subnet_id].append(eni_id)

#     return subnet_to_enis

# def subnet_ec2(ec2_data):
#     subnet_to_ec2_map = defaultdict(list)

#     for ec2 in ec2_data:
#         subnet_id = ec2["subnet_id"]
#         instance_id = ec2["instance_id"]
#         subnet_to_ec2_map[subnet_id].append(instance_id)

#     # Output the result
#     for subnet, instances in subnet_to_ec2_map.items():
#         print(f"Subnet: {subnet}, EC2 Count: {len(instances)}, EC2 Instances: {instances}")