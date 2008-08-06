#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_monitoring::rmcmon;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use strict;
use xCAT::NodeRange;
use Sys::Hostname;
use Socket;
use xCAT::Utils;
use xCAT::GlobalDef;
use xCAT_monitoring::monitorctrl;
use xCAT::MsgUtils;

#print "xCAT_monitoring::rmcmon loaded\n";
1;


#TODO: script to define sensors on the nodes.
#TODO: how to push the sensor scripts to nodes?
#TODO: what to do when stop is called? stop all the associations or just the ones that were predefined? or leve them there?
#TODO: monitoring HMC with old RSCT and new RSCT

#-------------------------------------------------------------------------------
=head1  xCAT_monitoring:rmcmon  
=head2    Package Description
  xCAT monitoring plugin package to handle RMC monitoring.
=cut
#-------------------------------------------------------------------------------

#--------------------------------------------------------------------------------
=head3    start
      This function gets called by the monitorctrl module
      when xcatd starts and when monstart command is issued by the user. 
      It starts the daemons and does necessary startup process for the RMC monitoring.
      It also queries the RMC for its currently monitored
      nodes which will, in tern, compared with the nodes
      in the input parameter. It asks RMC to add or delete
      nodes according to the comparison so that the nodes
      monitored by RMC are in sync with the nodes currently
      in the xCAT cluster.
       p_nodes -- a pointer to an arrays of nodes to be monitored. null means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means localhost only. 
                2 means both localhost and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
      (return code, message) 
      if the callback is set, use callback to display the status and error. 
=cut
#--------------------------------------------------------------------------------
sub start {
  print "rmcmon::start called\n";
  my $noderef=shift;
  if ($noderef =~ /xCAT_monitoring::rmcmon/) {
    $noderef=shift;
  }
  my $scope=shift;
  my $callback=shift;

  my $localhostname=hostname();
    
  #assume the server is the current node.
  #check if rsct is installed and running
  if (! -e "/usr/bin/lsrsrc") {
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: RSCT is not installed.";
      $callback->($rsp);
    }
    return (1, "RSCT is not installed.\n");
  }

  my $result;
  chomp(my $pid= `/bin/ps -ef | /bin/grep rmcd | /bin/grep -v grep | /bin/awk '{print \$2}'`);
  unless($pid){
    #restart rmc daemon
    $result=`startsrc -s ctrmc`;
    if ($?) {
      if ($callback) {
        my $rsp={};
        $rsp->{data}->[0]="$localhostname: RMC deamon cannot be started.";
        $callback->($rsp);
      }
      return (1, "RMC deamon cannot be started\n");
    }
    `startsrc -s  IBM.MgmtDomainRM`;
  }

  #TODO: start all associations if they are not started

  if ($scope) {
    #get a list of managed nodes
    $result=`/usr/bin/lsrsrc-api -s IBM.MngNode::::Name 2>&1`;  
    if ($?) {
      if ($result !~ /2612-023/) {#2612-023 no resources found error
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $result.";
          $callback->($rsp);
        } else {
          xCAT::MsgUtils->message('S', "[mon]: $result\n");
        }
        return (1,$result);
      }
      $result='';
    }
    chomp($result);
    my @rmc_nodes=split(/\n/, $result);
    
    #start the rmc daemons for its children
    if (@rmc_nodes > 0) {
      my $nodestring=join(',', @rmc_nodes);
      $result=`XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring startsrc -s ctrmc 2>&1`;
      if (($result) && ($result !~ /0513-029/)) { #0513-029 multiple instance not supported.
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $result\n";
          $callback->($rsp);
        } else {
          xCAT::MsgUtils->message('S', "[mon]: $result\n");
        }
      }
    }
  }

  if ($callback) {
    my $rsp={};
    $rsp->{data}->[0]="$localhostname: done.";
    $callback->($rsp);
  }

  return (0, "started");
}


#--------------------------------------------------------------------------------
=head3    pingNodeStatus
      This function takes an array of nodes and returns their status using fping.
    Arguments:
       nodes-- an array of nodes.
    Returns:
       a hash that has the node status. The format is: 
          {active=>[node1, node3,...], unreachable=>[node4, node2...]}
=cut
#--------------------------------------------------------------------------------
sub pingNodeStatus {
  my ($class, @mon_nodes)=@_;
  my %status=();
  my @active_nodes=();
  my @inactive_nodes=();
  if ((@mon_nodes)&& (@mon_nodes > 0)) {
    #get all the active nodes
    my $nodes= join(' ', @mon_nodes);
    my $temp=`fping -a $nodes 2> /dev/null`;
    chomp($temp);
    @active_nodes=split(/\n/, $temp);

    #get all the inactive nodes by substracting the active nodes from all.
    my %temp2;
    if ((@active_nodes) && ( @active_nodes > 0)) {
      foreach(@active_nodes) { $temp2{$_}=1};
        foreach(@mon_nodes) {
          if (!$temp2{$_}) { push(@inactive_nodes, $_);}
        }
    }
    else {@inactive_nodes=@mon_nodes;}     
  }

  $status{$::STATUS_ACTIVE}=\@active_nodes;
  $status{$::STATUS_INACTIVE}=\@inactive_nodes;
 
  return %status;
}



#--------------------------------------------------------------------------------
=head3    stop
      This function gets called by the monitorctrl module when
      xcatd stops or when monstop command is issued by the user. 
      It stops the monitoring on all nodes, stops
      the daemons and does necessary cleanup process for the
      RMC monitoring.
    Arguments:
       p_nodes -- a pointer to an arrays of nodes to be stoped for monitoring. null means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means localhost only. 
                2 means both monservers and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
      (return code, message) 
      if the callback is set, use callback to display the status and error. 
=cut
#--------------------------------------------------------------------------------
sub stop {
  print "rmcmon::stop called\n";
  my $noderef=shift;
  if ($noderef =~ /xCAT_monitoring::rmcmon/) {
    $noderef=shift;
  }
  my $scope=shift;
  my $callback=shift;

  my $localhostname=hostname();

  #TODO: stop condition-response associtations. 
  my $result;
  chomp(my $pid= `/bin/ps -ef | /bin/grep rmcd | /bin/grep -v grep | /bin/awk '{print \$2}'`);
  if ($pid){
    #restop the rmc daemon
    $result=`stopsrc -s ctrmc`;
    if ($?) {
      if ($callback) {
        my $rsp={};
        $rsp->{data}->[0]="$localhostname: RMC deamon cannot be stopped.";
        $callback->($rsp);
      }
      return (1, "RMC deamon cannot be stopped\n");
    }
  }

  if ($scope) {
    my $pPairHash=xCAT_monitoring::monitorctrl->getMonServer($noderef);
 
    #the identification of this node
    my @hostinfo=xCAT::Utils->determinehostname();
    my $isSV=xCAT::Utils->isServiceNode();
    my %iphash=();
    foreach(@hostinfo) {$iphash{$_}=1;}
    if (!$isSV) { $iphash{'noservicenode'}=1;}

    foreach my $key (keys (%$pPairHash)) {
      my @key_a=split(',', $key);
      if (! $iphash{$key_a[0]}) { next;}   
      my $mon_nodes=$pPairHash->{$key};

      #figure out what nodes to stop
      my @nodes_to_stop=();
      if ($mon_nodes) {
        foreach(@$mon_nodes) {
          my $node=$_->[0];
          my $nodetype=$_->[1];
          if (($nodetype) && ($nodetype =~ /$::NODETYPE_OSI/)) { 
	    push(@nodes_to_stop, $node);
          }  
        }     
      }

      if (@nodes_to_stop > 0) {
      my $nodestring=join(',', @nodes_to_stop);
      #$result=`XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring stopsrc -s ctrmc 2>&1`;
      $result=`XCATBYPASS=Y $::XCATROOT/bin/xdsh $nodestring "/bin/ps -ef | /bin/grep rmcd | /bin/grep -v grep | /bin/awk '{if (\\\$2>0) system(\\\"stopsrc -s ctrmc\\\")}' 2>&1"`;

      if (($result) && ($result !~ /0513-044/)){ #0513-0544 is normal value
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $result\n";
          $callback->($rsp);
        } else {
          xCAT::MsgUtils->message('S', "[mon]: $result\n");
        }
      }
    }
  }

  return (0, "stopped");
}



#--------------------------------------------------------------------------------
=head3    config
      This function configures the cluster for the given nodes.  
      This function is called when moncfg command is issued or when xcatd starts
      on the service node. It will configure the cluster to include the given nodes within
      the monitoring doamin. 
    Arguments:
       p_nodes -- a pointer to an arrays of nodes to be added for monitoring. none means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means localhost only. 
                2 means localhost and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
       (error code, error message)
=cut
#--------------------------------------------------------------------------------
sub config {
  print "rmcmon:config called\n";
  my $noderef=shift;
  if ($noderef =~ /xCAT_monitoring::rmcmon/) {
    $noderef=shift;
  }
  my $scope=shift;
  my $callback=shift;

  my $localhostname=hostname();
    
  #assume the server is the current node.
  #check if rsct is installed and running
  if (! -e "/usr/bin/lsrsrc") {
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: RSCT is not installed.";
      $callback->($rsp);
    }
    return (1, "RSCT is not installed.\n");
  }

  my $result;
  chomp(my $pid= `/bin/ps -ef | /bin/grep rmcd | /bin/grep -v grep | /bin/awk '{print \$2}'`);
  unless($pid){
    #restart rmc daemon
    $result=`startsrc -s ctrmc`;
    if ($?) {
     if ($callback) {
       my $rsp={};
       $rsp->{data}->[0]="$localhostname: RMC deamon cannot be started.";
       $callback->($rsp);
     }
     return (1, "RMC deamon cannot be started\n");
    }
  }

  #enable remote client connection
  `/usr/bin/rmcctrl -p`;
  
  my $pPairHash=xCAT_monitoring::monitorctrl->getMonServer($noderef);
 
  #the identification of this node
  my @hostinfo=xCAT::Utils->determinehostname();
  my $isSV=xCAT::Utils->isServiceNode();
  my %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}
  if (!$isSV) { $iphash{'noservicenode'}=1;}

  foreach my $key (keys (%$pPairHash)) {
    my @key_a=split(',', $key);
    if (! $iphash{$key_a[0]}) { next;}   
    my $mon_nodes=$pPairHash->{$key};
    my $master=$key_a[1];

    #figure out what nodes to add
    my @nodes_to_add=();
    if ($mon_nodes) {
      foreach(@$mon_nodes) {
        my $node=$_->[0];
        my $nodetype=$_->[1];
        if (($nodetype) && ($nodetype =~ /$::NODETYPE_OSI/)) { 
	  push(@nodes_to_add, $node);
        }  
      }     
    }

    #add new nodes to the RMC cluster
    addNodes(\@nodes_to_add, $master, $scope, $callback);
  }

  #create conditions/responses/sensors on the service node or mn
  my $result=`$::XCATROOT/sbin/rmcmon/mkrmcresources $::XCATROOT/lib/perl/xCAT_monitoring/rmc/resources/sn 2>&1`;
  if ($?) {
    my $error= "Error when creating predefined resources on $localhostname:\n$result";
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: $error.";
      $callback->($rsp);
    } else {   xCAT::MsgUtils->message('S', "[mon]: $error\n"); }
  }   
  if ($isSV) {
    $result=`$::XCATROOT/sbin/rmcmon/mkrmcresources $::XCATROOT/lib/perl/xCAT_monitoring/rmc/resources/node 2>&1`; 
  } else  {
    $result=`$::XCATROOT/sbin/rmcmon/mkrmcresources $::XCATROOT/lib/perl/xCAT_monitoring/rmc/resources/mn 2>&1`; 
  }      
  if ($?) {
    my $error= "Error when creating predefined resources on $localhostname:\n$result";
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: $error.";
      $callback->($rsp);
    } else { xCAT::MsgUtils->message('S', "[mon]: $error\n"); }
  }
}

#--------------------------------------------------------------------------------
=head3    deconfig
      This function de-configures the cluster for the given nodes.  
      This function is called when mondecfg command is issued by the user. 
      It should remove the given nodes from the product for monitoring.
    Arguments:
       p_nodes -- a pointer to an arrays of nodes to be removed for monitoring. none means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
       (error code, error message)
=cut
#--------------------------------------------------------------------------------
sub deconfig {
  print "rmcmon:deconfig called\n";
  my $noderef=shift;
  if ($noderef =~ /xCAT_monitoring::rmcmon/) {
    $noderef=shift;
  }
  my $scope=shift;
  my $callback=shift;
  my $localhostname=hostname();
  my $pPairHash=xCAT_monitoring::monitorctrl->getMonServer($noderef);
 
  #the identification of this node
  my @hostinfo=xCAT::Utils->determinehostname();
  my $isSV=xCAT::Utils->isServiceNode();
  my %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}
  if (!$isSV) { $iphash{'noservicenode'}=1;}

  foreach my $key (keys (%$pPairHash)) {
    my @key_a=split(',', $key);
    if (! $iphash{$key_a[0]}) { next;}   
    my $mon_nodes=$pPairHash->{$key};
    my $master=$key_a[1];

    #figure out what nodes to remove
    my @nodes_to_rm=();
    if ($mon_nodes) {
      foreach(@$mon_nodes) {
        my $node=$_->[0];
        my $nodetype=$_->[1];
        if (($nodetype) && ($nodetype =~ /$::NODETYPE_OSI/)) { 
	  push(@nodes_to_rm, $node);
        }  
      }     
    }

    #remove nodes from the RMC cluster
    removeNodes(\@nodes_to_rm, $master, $scope, $callback);}
  } 
}

#--------------------------------------------------------------------------------
=head3    supportNodeStatusMon
    This function is called by the monitorctrl module to check
    if RMC can help monitoring and returning the node status.
    
    Arguments:
        none
    Returns:
         1  
=cut
#--------------------------------------------------------------------------------
sub supportNodeStatusMon {
  #print "rmcmon::supportNodeStatusMon called\n";
  return 1;
}



#--------------------------------------------------------------------------------
=head3   startNodeStatusMon
    This function is called by the monitorctrl module to tell
    RMC to start monitoring the node status and feed them back
    to xCAT. RMC will start setting up the condition/response 
    to monitor the node status changes.  

    Arguments:
       p_nodes -- a pointer to an arrays of nodes for monitoring. none means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
       (error code, error message)
=cut
#--------------------------------------------------------------------------------
sub startNodeStatusMon {
  print "rmcmon::startNodeStatusMon\n";
  my $noderef=shift;
  if ($noderef =~ /xCAT_monitoring::rmcmon/) {
    $noderef=shift;
  }
  my $scope=shift;
  my $callback=shift;

  my $localhostname=hostname();
  my $retcode=0;
  my $retmsg="";


  my $isSV=xCAT::Utils->isServiceNode();
  if ($isSV) { return  ($retcode, $retmsg); } 


  #get all the nodes status from IBM.MngNode class of local host and 
  #the identification of this node
  my $pPairHash=xCAT_monitoring::monitorctrl->getMonServer($noderef);

  my @hostinfo=xCAT::Utils->determinehostname();
  my %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}
  if (!$isSV) { $iphash{'noservicenode'}=1;}

  my @servicenodes=();
  my %status_hash=();
  foreach my $key (keys (%$pPairHash)) {
    my @key_a=split(',', $key);
    if (! $iphash{$key_a[0]}) { push @servicenodes, $key_a[0]; } 
    my $mon_nodes=$noderef->{$key};
    foreach(@$mon_nodes) {
      my $node_info=$_;
      $status_hash{$node_info->[0]}=$node_info->[2];
    }
  }

  #get nodestatus from RMC and update the xCAT DB
  ($retcode, $retmsg) = saveRMCNodeStatusToxCAT(\%status_hash);
  if ($retcode != 0) {
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: $retmsg.";
      $callback->($rsp);
    } else {   xCAT::MsgUtils->message('S', "[mon]: $retmsg\n"); }
  }
  foreach (@servicenodes) {
    ($retcode, $retmsg) = saveRMCNodeStatusToxCAT(\%status_hash, $_);
    if ($retcode != 0) {
      if ($callback) {
        my $rsp={};
        $rsp->{data}->[0]="$localhostname: $retmsg.";
        $callback->($rsp);
      } else {   xCAT::MsgUtils->message('S', "[mon]: $retmsg\n"); }
    }
  }

  #start monitoring the status of mn's immediate children
  my $result=`startcondresp NodeReachability UpdatexCATNodeStatus 2>&1`;
  if ($?) {
    $retcode=$?;
    $retmsg="Error start node status monitoring: $result";
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: $retmsg.";
      $callback->($rsp);
    } else {   xCAT::MsgUtils->message('S', "[mon]: $retmsg\n"); }
  }

  #start monitoring the status of mn's grandchildren via their service nodes
  $result=`startcondresp NodeReachability_H UpdatexCATNodeStatus 2>&1`;
  if ($?) {
    $retcode=$?;
    $retmsg="Error start node status monitoring: $result";
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: $retmsg.";
      $callback->($rsp);
    } else {   xCAT::MsgUtils->message('S', "[mon]: $retmsg\n"); }
  }
 
  return ($retcode, $retmsg);
}


#--------------------------------------------------------------------------------
=head3   saveRMCNodeStatusToxCAT
    This function gets RMC node status and save them to xCAT database

    Arguments:
        $oldstatus a pointer to a hash table that has the current node status
        $node  the name of the service node to run RMC command from. If null, get from local host. 
    Returns:
        (return code, message)
=cut
#--------------------------------------------------------------------------------
sub saveRMCNodeStatusToxCAT {
  #print "rmcmon::saveRMCNodeStatusToxCAT called\n";
  my $retcode=0;
  my $retmsg="started";
  my $statusref=shift;
  if ($statusref =~ /xCAT_monitoring::rmcmon/) {
    $statusref=shift;
  }
  my $node=shift;

  my %status_hash=%$statusref;

  #get all the node status from mn's children
  my $result;
  my @active_nodes=();
  my @inactive_nodes=();
  if ($node) {
    $result=`CT_MANAGEMENT_SCOPE=4 /usr/bin/lsrsrc-api -o IBM.MngNode::::$node::Name::Status 2>&1`;
  } else {
    $result=`CT_MANAGEMENT_SCOPE=1 /usr/bin/lsrsrc-api -s IBM.MngNode::::Name::Status 2>&1`;
  }
  if ($?) {
    $retcode=$?;
    $retmsg=$result;
    xCAT::MsgUtils->message('SI', "[mon]: Error getting node status from RMC: $result\n");
    return ($retcode, $retmsg);
  } else {
    if ($result) {
      my @lines=split('\n', $result);
      #only save the ones that needs to change
      foreach (@lines) {
	my @pairs=split('::', $_);
        if ($pairs[1]==1) { 
          if ($status_hash{$pairs[0]} ne $::STATUS_ACTIVE) { push @active_nodes,$pairs[0];} 
        }
        else { 
          if ($status_hash{$pairs[0]} ne $::STATUS_INACTIVE) { push @inactive_nodes, $pairs[0];}
        }  
      } 
    }
  }

  my %new_node_status=();
  if (@active_nodes>0) {
    $new_node_status{$::STATUS_ACTIVE}=\@active_nodes;
  } 
  if (@inactive_nodes>0) {
    $new_node_status{$::STATUS_INACTIVE}=\@inactive_nodes;
  }
  #only set the node status for the changed ones
  if (keys(%new_node_status) > 0) {
    xCAT_monitoring::monitorctrl::setNodeStatusAttributes(\%new_node_status);
  }  
  return ($retcode, $retmsg);
}




#--------------------------------------------------------------------------------
=head3   stopNodeStatusMon
    This function is called by the monitorctrl module to tell
    RMC to stop feeding the node status info back to xCAT. It will
    stop the condition/response that is monitoring the node status.

    Arguments:
       p_nodes -- a pointer to an arrays of nodes for monitoring. none means all.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means local host only. 
                2 means both local host and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
        (return code, message)
=cut
#--------------------------------------------------------------------------------
sub stopNodeStatusMon {
  print "rmcmon::stopNodeStatusMon called\n";
  my $noderef=shift;
  if ($noderef =~ /xCAT_monitoring::rmcmon/) {
    $noderef=shift;
  }
  my $scope=shift;
  my $callback=shift;

  my $retcode=0;
  my $retmsg="";

  my $isSV=xCAT::Utils->isServiceNode();
  if ($isSV) { return  ($retcode, $retmsg); }
  my $localhostname=hostname();
 
  #stop monitoring the status of mn's immediate children
  my $result=`stopcondresp NodeReachability UpdatexCATNodeStatus 2>&1`;
  if ($?) {
    $retcode=$?;
    $retmsg="Error stop node status monitoring: $result";
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: $retmsg.";
      $callback->($rsp);
    } else {   xCAT::MsgUtils->message('S', "[mon]: $retmsg\n"); }
  }

  #stop monitoring the status of mn's grandchildren via their service nodes
  $result=`stopcondresp NodeReachability_H UpdatexCATNodeStatus 2>&1`;
  if ($?) {
    $retcode=$?;
    $retmsg="Error stop node status monitoring: $result";
    if ($callback) {
      my $rsp={};
      $rsp->{data}->[0]="$localhostname: $retmsg.";
      $callback->($rsp);
    } else {   xCAT::MsgUtils->message('S', "[mon]: $retmsg\n"); }
  }
  return ($retcode, $retmsg);
}


#--------------------------------------------------------------------------------
=head3   getNodeID
    This function gets the nodeif for the given node.

    Arguments:
        node
    Returns:
        node id for the given node
=cut
#--------------------------------------------------------------------------------
sub getNodeID {
  my $node=shift;
  if ($node =~ /xCAT_monitoring::rmcmon/) {
    $node=shift;
  }
  my $tab=xCAT::Table->new("mac", -create =>0);
  my $tmp=$tab->getNodeAttribs($node, ['mac']);
  if (defined($tmp) && ($tmp)) {
    my $mac=$tmp->{mac};
    $mac =~ s/://g;
    $mac = "EA" . $mac . "EA";
    $tab->close();
    return $mac;  
  }
  $tab->close();
  return undef;
}

#--------------------------------------------------------------------------------
=head3   getLocalNodeID
    This function goes to RMC and gets the nodeid for the local host.

    Arguments:
        node
    Returns:
        node id for the local host.
=cut
#--------------------------------------------------------------------------------
sub getLocalNodeID {
  my $node_id=`/usr/sbin/rsct/bin/lsnodeid`;
  if ($?==0) {
    chomp($node_id);
    return $node_id;
  } else {
    return undef;
  }
}

#--------------------------------------------------------------------------------
=head3    getNodeInfo
      This function gets the nodeid, node ip addresses for the given node 
    Arguments:
       node  
    Returns:
       (nodeid, nodeip)
=cut
#--------------------------------------------------------------------------------
sub getNodeInfo 
{
  my $node=shift;
  my @hostinfo=xCAT::Utils->determinehostname();
  my %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}

  my $node_id;
  if($iphash{$node}) {
    $node_id=getLocalNodeID();
  } else { 
    $node_id=getNodeID($node);
  }

  my ($name,$aliases,$addrtype,$length,@addrs) = gethostbyname($node);
  chomp($name);
  my $ipaddresses="{";
  foreach (@addrs) { $ipaddresses .= '"'.inet_ntoa($_) . '",'; }
  chop($ipaddresses);
  $ipaddresses .= "}";

  return ($node_id, $ipaddresses);
}

#--------------------------------------------------------------------------------
=head3    addNodes
      This function gdds the nodes into the RMC cluster, it does not check the OSI type and
      if the node has already defined. 
    Arguments:
       nodes --an array of nodes to be added. 
       master -- the monitoring master of the node.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means localhost only. 
                2 means localhost and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
       (error code, error message)
=cut
#--------------------------------------------------------------------------------
sub addNodes {
  my $pmon_nodes=shift;
  if ($pmon_nodes =~ /xCAT_monitoring::rmcmon/) {
    $pmon_nodes=shift;
  }

  my @mon_nodes = @$pmon_nodes;
  my $master=shift;
  my $scope=shift;
  my $callback=shift;

  #print "rmcmon::addNodes_noChecking get called with @mon_nodes\n";
  my @hostinfo=xCAT::Utils->determinehostname();
  my %iphash=();
  foreach(@hostinfo) {$iphash{$_}=1;}
  my $localhostname=hostname();

  #find in active nodes
  my $inactive_nodes=[];
  if ($scope) { 
    my %nodes_status=xCAT_monitoring::rmcmon->pingNodeStatus(@mon_nodes); 
    $inactive_nodes=$nodes_status{$::STATUS_INACTIVE};
    #print "active nodes to add:@$active_nodes\ninactive nodes to add: @$inactive_nodes\n";
    if (@$inactive_nodes>0) { 
      my $error="The following nodes cannot be added to the RMC cluster because they are inactive:\n  @$inactive_nodes.";
      if ($callback) {
        my $rsp={};
        $rsp->{data}->[0]="$localhostname: $error";
        $callback->($rsp);
      } else { xCAT::MsgUtils->message('S', "[mon]: $error\n"); }
    }
  }
  my %inactiveHash=();
  foreach(@$inactive_nodes) { $inactiveHash{$_}=1;} 

  #get a list of managed nodes
  my $result=`/usr/bin/lsrsrc-api -s IBM.MngNode::::Name 2>&1`;  
  if ($?) {
    if ($result !~ /2612-023/) {#2612-023 no resources found error
      if ($callback) {
        my $rsp={};
        $rsp->{data}->[0]="$localhostname: $result.";
        $callback->($rsp);
      } else { xCAT::MsgUtils->message('S', "[mon]: $result\n"); }
      return (1,$result);
    }
    $result='';
  }
  chomp($result);
  my @rmc_nodes=split(/\n/, $result);
  my %rmcHash=();
  foreach (@rmc_nodes) { $rmcHash{$_}=1;}


  my $ms_host_name=$localhostname;
  my $ms_node_id;
  my $mn_node_id;
  my $ms_ipaddresses;
  my $mn_ipaddresses;
  my $result;
  my $first_time=1;

  foreach my $node(@mon_nodes) {
    #get info for the node
    ($mn_node_id, $mn_ipaddresses)=getNodeInfo($node);
    #get mn info
    if ($first_time) {
      ($ms_node_id, $ms_ipaddresses)=getNodeInfo($ms_host_name);
      $first_time=0;
    }

    if (!$rmcHash{$node}) {
      # define resource in IBM.MngNode class on server
      $result=`mkrsrc-api IBM.MngNode::Name::"$node"::KeyToken::"$node"::IPAddresses::"$mn_ipaddresses"::NodeID::0x$mn_node_id 2>&1`;
      if ($?) {
        my $error= "define resource in IBM.MngNode class result=$result.";
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $error.";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $error\n"); }
        next; 
      }
    }

    if ($scope==0) { next; }
    if ($inactiveHash{$node}) { next;}

    #copy the configuration script and run it locally
    if($iphash{$node}) {
      $result=`/usr/bin/mkrsrc-api IBM.MCP::MNName::"$node"::KeyToken::"$master"::IPAddresses::"$ms_ipaddresses"::NodeID::0x$ms_node_id`;      
      if ($?) {
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $result.";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $result\n");}
        next;
      }
    } else {
      $result=`XCATBYPASS=Y  $::XCATROOT/bin/xdcp $node $::XCATROOT/sbin/rmcmon/configrmcnode /tmp 2>&1`;
      if ($?) {
	my $error="cannot copy the file configrmcnode to node $node";
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $error.";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $error\n");}
        next;
      }
      $result=`XCATBYPASS=Y $::XCATROOT/bin/xdsh $node NODE=$node NODEID=$mn_node_id MONMASTER=$master MS_NODEID=$ms_node_id /tmp/configrmcnode 1 2>&1`;
      if ($?) {
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $result.";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $result\n"); }
      }
    }
  } 

  return (0, "ok"); 
}


#--------------------------------------------------------------------------------
=head3    removeNodes
      This function removes the nodes from the RMC cluster.
    Arguments:
      nodes --a pointer to a array of node names to be removed. 
      master -- the master of the nodes.
       scope -- the action scope, it indicates the node type the action will take place.
                0 means localhost only. 
                2 means localhost and nodes, 
       callback -- the callback pointer for error and status displaying. It can be null.
    Returns:
      (error code, error message)
=cut
#--------------------------------------------------------------------------------
sub removeNodes {
  my $pmon_nodes=shift;
  if ($pmon_nodes =~ /xCAT_monitoring::rmcmon/) {
    $pmon_nodes=shift;
  }
  my @mon_nodes = @$pmon_nodes;
  my $master=shift;
  my $scope=shift;
  my $callback=shift;

  my $localhostname=hostname();
  my $ms_host_name=$localhostname;
  my $ms_node_id;
  my $ms_ipaddresses;
  my $result;
  my $first_time=1;
 
  #find in active nodes
  my $inactive_nodes=[];
  if ($scope) { 
    my %nodes_status=xCAT_monitoring::rmcmon->pingNodeStatus(@mon_nodes); 
    $inactive_nodes=$nodes_status{$::STATUS_INACTIVE};
    #print "active nodes to add:@$active_nodes\ninactive nodes to add: @$inactive_nodes\n";
    if (@$inactive_nodes>0) { 
      my $error="The following nodes cannot be removed from the RMC cluster because they are inactive:\n  @$inactive_nodes.";
      if ($callback) {
        my $rsp={};
        $rsp->{data}->[0]="$localhostname: $error.";
        $callback->($rsp);
      } else { xCAT::MsgUtils->message('S', "[mon]: $error\n"); }
    }
  }
  my %inactiveHash=();
  foreach(@$inactive_nodes) { $inactiveHash{$_}=1;} 

  #get a list of managed nodes
  my $result=`/usr/bin/lsrsrc-api -s IBM.MngNode::::Name 2>&1`;  
  if ($?) {
    if ($result !~ /2612-023/) {#2612-023 no resources found error
      if ($callback) {
        my $rsp={};
        $rsp->{data}->[0]="$localhostname: $result.";
        $callback->($rsp);
      } else { xCAT::MsgUtils->message('S', "[mon]: $result\n");}
      return (1,$result);
    }
    $result='';
  }
  chomp($result);
  my @rmc_nodes=split(/\n/, $result);
  my %rmcHash=();
  foreach (@rmc_nodes) { $rmcHash{$_}=1;}

  #print "rmcmon::removeNodes_noChecking get called with @mon_nodes\n";

  foreach my $node (@mon_nodes) {
    if ($rmcHash{$node}) {
      #remove resource in IBM.MngNode class on server
      my $result=`rmrsrc-api -s IBM.MngNode::"Name=\\\"\"$node\\\"\"" 2>&1`;
      if ($?) {  
        if ($result =~ m/2612-023/) { #resource not found
         next;
        }
        my $error="Remove resource in IBM.MngNode class result=$result.";
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $error";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $error\n");}
      }
    }

    if ($scope==0) { next; }
    if ($inactiveHash{$node}) { next;}

    if ($ms_host_name eq $node) {
      $result= `/usr/bin/rmrsrc-api -s IBM.MCP::"MNName=\\\"\"$node\\\"\"" 2>&1`;
      if ($?) {
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $result";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $result\n");}
      }
    } else {
      #copy the configuration script and run it locally
      $result=`XCATBYPASS=Y $::XCATROOT/bin/xdcp $node $::XCATROOT/sbin/rmcmon/configrmcnode /tmp 2>&1 `;
      if ($?) {
	my $error="rmcmon:removeNodes: cannot copy the file configrmcnode to node $node.";
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $error";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $error\n");}
        next;
      }

      #get mn info
      if ($first_time) {
        ($ms_node_id, $ms_ipaddresses)=getNodeInfo($ms_host_name);
        $first_time=0;
      }
      $result=`XCATBYPASS=Y $::XCATROOT/bin/xdsh $node NODE=$node MS_NODEID=$ms_node_id /tmp/configrmcnode -1 2>&1`;
      if ($?) {
        if ($callback) {
          my $rsp={};
          $rsp->{data}->[0]="$localhostname: $result";
          $callback->($rsp);
        } else { xCAT::MsgUtils->message('S', "[mon]: $result\n");}
      }
    }
  }           

  return (0, "ok");
}

#--------------------------------------------------------------------------------
=head3    processSettingChanges
      This function gets called when the setting for this monitoring plugin 
      has been changed in the monsetting table.
    Arguments:
       none.
    Returns:
        0 for successful.
        non-0 for not successful.
=cut
#--------------------------------------------------------------------------------
sub processSettingChanges {
}

#--------------------------------------------------------------------------------
=head3    getDiscription
      This function returns the detailed description of the plugin inluding the
     valid values for its settings in the monsetting tabel. 
     Arguments:
        none
    Returns:
        The description.
=cut
#--------------------------------------------------------------------------------
sub getDescription {
  return 
"  Description:
    rmcmon uses IBM's Resource Monitoring and Control (RMC) component 
    of Reliable Scalable Cluster Technology (RSCT) to monitor the 
    xCAT cluster. RMC has built-in resources such as CPU, memory, 
    process, network, file system etc for monitoring. RMC can also be 
    used to provide node liveness status monitoring for xCAT. RMC is 
    good for threadhold monitoring. xCAT automatically sets up the 
    monitoring domain for RMC during node deployment time. To start 
    RMC monitoring, use
      monstart rmcmon
    or 
      monstart rmcmon -n   (to include node status monitoring).
  Settings:
    none.";
}

#--------------------------------------------------------------------------------
=head3    getNodeConfData
      This function gets a list of configuration data that is needed by setting up
    node monitoring.  These data-value pairs will be used as environmental variables 
    on the given node.
    Arguments:
        node  
        pointer to a hash that will take the data.
    Returns:
        none
=cut
#--------------------------------------------------------------------------------
sub getNodeConfData {
  #check if rsct is installed or not
  if (! -e "/usr/bin/lsrsrc") {
    return;
  }

  my $node=shift;
  if ($node =~ /xCAT_monitoring::rmcmon/) {
    $node=shift;
  }
  my $ref_ret=shift;

  #get node ids for RMC monitoring
  my $nodeid=xCAT_monitoring::rmcmon->getNodeID($node);
  if (defined($nodeid)) {
    $ref_ret->{NODEID}=$nodeid;
  }
  my $ms_nodeid=xCAT_monitoring::rmcmon->getLocalNodeID();
  if (defined($ms_nodeid)) {
    $ref_ret->{MS_NODEID}=$ms_nodeid;
  }
  return;
}

#--------------------------------------------------------------------------------
=head3    getPostscripts
      This function returns the postscripts needed for the nodes and for the servicd
      nodes. 
     Arguments:
        none
    Returns:
     The the postscripts. It a pointer to an array with the node group names as the keys
    and the comma separated poscript names as the value. For example:
    {service=>"cmd1,cmd2", xcatdefaults=>"cmd3,cmd4"} where xcatdefults is a group
    of all nodes including the service nodes.
=cut
#--------------------------------------------------------------------------------
sub getPostscripts {
  my $ret={};
  $ret->{xcatdefaults}="configrmcnode";
  return $ret;

}
