#!/bin/sh
# Original Author: Unknown 
# Forked from http://media.amazonwebservices.com/articles/nat_monitor_files/nat_monitor.sh
# Author: Robert Grignon 
# Email: robert@unifiedservices.net
# Date: 07/14/2014
# This script will monitor a UTM instance and reassign its routes
# if communication with the instance fails

#UTM instance variables
UTM_NAME=utm1.domain.com                        #Instance Name
UTM_ID=i-83dfc2d0                               #Instance ID
UTM_IP=10.100.1.100                             #Instance IP
UTM_PRI_ENI=eni-54c2b24e                        #Primary ENI (Should be the ENI of the Primary UTM Server
UTM_SEC_ENI=eni-909f993s                        #Secondary ENI (Used if there is a problem with Primary UTM Server)
UTM_CIDR="10.200.0.0/16"                        #CIDR for other region
UTM_RT=rtb-2da75032                             #Route Table that the Primary UTM Server is part of

EC2_URL=https://ec2.us-east-1.amazonaws.com     #Specify the EC2 region that this will be running in

# Health Check variables
Num_Pings=3
Ping_Timeout=1
Wait_Between_Pings=2
Wait_for_Instance_Stop=60
Wait_for_Instance_Start=300

# Run aws-apitools-common.sh to set up default environment variables and to
# leverage AWS security credentials provided by EC2 roles
. /etc/profile.d/aws-apitools-common.sh

logger "Starting UTM monitor: Monitoring - $UTM_IP"
logger "Adding this $UTM_NAME($UTM_PRI_ENI) to $UTM_RT (default route) on start"
/opt/aws/bin/ec2-replace-route $UTM_RT -r $UTM_CIDR -n $UTM_PRI_ENI -U $EC2_URL

# If replace-route failed, then the route might not exist and may need to be created instead
if [ "$?" != "0" ]; then
  /opt/aws/bin/ec2-create-route $UTM_RT -r $UTM_CIDR -n $UTM_PRI_ENI -U $EC2_URL
fi

while [ . ]; do
  # Check health of other UTM instance
  pingresult=`ping -c $Num_Pings -W $Ping_Timeout $UTM_IP | grep time= | wc -l`
  # Check to see if any of the health checks succeeded, if not
  if [ "$pingresult" == "0" ]; then
    # Set HEALTHY variables to unhealthy (0)
    ROUTE_HEALTHY=0
    UTM_HEALTHY=0
    STOPPING_UTM=0
    while [ "$UTM_HEALTHY" == "0" ]; do
      # UTM instance is unhealthy, loop while we try to fix it
      if [ "$ROUTE_HEALTHY" == "0" ]; then
        logger "UTM heartbeat failed ($UTM_NAME), applying Secondary ENI($UTM_SEC_ENI) to Route $UTM_RT for $UTM_CIDR"
        /opt/aws/bin/ec2-replace-route $UTM_RT -r $UTM_CIDR -n $UTM_SEC_ENI -U $EC2_URL
        ROUTE_HEALTHY=1
      fi
      # Check UTM state to see if we should stop it or start it again
      UTM_STATE=`/opt/aws/bin/ec2-describe-instances $UTM_ID -U $EC2_URL | grep INSTANCE | awk '{print $6}'`
      if [ "$UTM_STATE" == "stopped" ]; then
        logger "UTM_NAME($UTM_ID) is stopped, starting it back up"
        /opt/aws/bin/ec2-start-instances $UTM_ID -U $EC2_URL
        UTM_HEALTHY=1
        sleep $Wait_for_Instance_Start
      else
        if [ "$STOPPING_UTM" == "0" ]; then
          logger "$UTM_NAME($UTM_ID) is $UTM_STATE, attempting to stop for reboot"
          /opt/aws/bin/ec2-stop-instances $UTM_ID -U $EC2_URL
          STOPPING_UTM=1
        fi
      sleep $Wait_for_Instance_Stop
      fi
    done
  else
    if [ "$ROUTE_HEALTHY" == "1" ]; then
      logger "$UTM_NAME is responding again, applying Primary ENI($UTM_PRI_ENI) to Route $UTM_RT (default route) for $UTM_CIDR"
      /opt/aws/bin/ec2-replace-route $UTM_RT -r $UTM_CIDR -n $UTM_PRI_ENI -U $EC2_URL
      ROUTE_HEALTHY=0
      sleep $Wait_Between_Pings
    else
      sleep $Wait_Between_Pings
    fi
  fi
done