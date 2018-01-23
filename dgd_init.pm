#
# Dead Gateway Detection Initialization
#
# Author: Susan Coulter
#  
# Update HIstory
#	2010-07-07 - Modified initialization for xcat2
#       2011-03-24 - Modified for perceus/toss
#                      hurricane is different as multiple CUs run by one master
#                      2 of them, a & b are one IB fabric, c is a separate IB fabric
#       2011-05-02 - Added enhancements from code review plus more
#       2011-04-16 - Removed xcat stuff, moved statics to config file, etc.
#       2012-06-20 - Added ability to configure how parallel to pexec,
#			check ospf status, verify campus connectivity,
#			other niceties
#       2013-05-16 - Added logic to handle multiple compute images for VM
#	2016-01-07 - Improved many facets of the code
#			configurable order of testing
#			signal catching to re-read config and/or restart test loop
#			addition of Lustre knowledge
#
#


unshift (@INC, "/usr/bin");

# Using Syslog  module
use Sys::Syslog;

sub set_environment {
  my $fname = "set_environment";
  my ($svc,$unit,$unit1,$unit2);

  &check_status;

  $ENV{HOME} = "/root";
  $ENV{USER} = "root";

#====================  statics  =============================================

  $ACTIVE = 0;
  $ETHCFG_SVC_START = "/usr/bin/ethcfg --force start";
  $INACTIVE_PARTIAL = 1;
  $INACTIVE_COMPLETE = 2;
  $INACTIVE = 3;
  $INSANE = "/etc/INSANE";
  $NUM_DEAD_IOS = 0;
  my $PEXEC = "/usr/bin/pexec";
  @STAT = ("ACTIVE", "PARTIAL FAILURE", "COMPLETE FAILURE","FAILED");

# array of function names for each test

  $FN{TEST_COMPUTE_TO_LUSTRE} = \&check_connectivity;
  $FN{TEST_COMPUTE_TO_SWITCH_GW} = \&check_connectivity;
  $FN{TEST_IO_NODE_DMESG} = \&future;
  $FN{TEST_IO_NODE_NETSTAT} = \&future;
  $FN{TEST_IO_NODE_LOG} = \&check_iolog;
  $FN{TEST_IO_NODE_TO_CAMPUS} = \&future;
  $FN{TEST_OSPF_LOGS} = \&check_ospf;
  $FN{TEST_CAMPUS_TO_ETH_GW} = \&check_connectivity;
  $FN{TEST_CAMPUS_TO_IO_ETH} = \&check_connectivity;
  $FN{TEST_INTERNAL_TO_IO_IB} = \&check_connectivity;
  $FN{TEST_COMPUTE_TO_SEC} = \&check_connectivity;
  $FN{TEST_COMPUTE_TO_SEC_GW} = \&check_connectivity;

# read configuration file

  &read_config();

#=====================  perceus specific  =================================

  my $vnfsroot = "/var/lib/perceus/vnfs";
  my $perceusroot = "/etc/perceus";
  my $nodes = $perceusroot."/nodes.conf";
  my $cut_param_io = "-c1-$cfg{CUT_PARAM_IO}";
  my $cut_param_comp = "-c1-$cfg{CUT_PARAM_COMPUTE}";

#===================  statics that depend on perceus data / configs  ==================

  $SSH_COMMAND = "/usr/bin/ssh -o ConnectTimeout=$cfg{SSH_TIMEOUT}";
  $NUM_IO_NODES = `grep $cfg{IO_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | wc -l`;

# If multiple images, range already set

  if (!($COMP_RANGE)) {
    $COMP_RANGE = "@".$cfg{COMPUTE_IMAGE};
  }

  $NUM_COMP_NODES = `grep $cfg{COMPUTE_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | wc -l`;

# Command to re-run ethcfg

  $ETHCFG_REDO = "$PEXEC -t $cfg{TIMEOUT_PEXEC} -P$cfg{PARALLEL_PEXEC} -pm $COMP_RANGE --ping --ssh $ETHCFG_SVC_START";

# Set compute node sample size

  $SAMPLE = $NUM_COMP_NODES * $cfg{PING_PERCENT};
  if ($SAMPLE > $cfg{PING_MAX}) { $SAMPLE = $cfg{PING_MAX}; }

# Create array for gw ips for consistency in tests

  $SN_GW[0] = $cfg{LOCAL_CAMPUS_GW};
  if ($cfg{SECONDARY_NIC}) {
    $SEC_GW[0] = $cfg{SECONDARY_GW};
  }

# set iolog fail name for saving a copy

  $FAILED_IOLOG_FILENAME = "$cfg{IOLOG_FILENAME}_FAILED";

# set Lustre service commands

  if ($cfg{LUSTRE_SVC} =~ /systemctl/) {
    ($svc,$unit) = split(/:/,$cfg{LUSTRE_SVC}, 2);
    if ($unit =~ /:/) {
      ($unit1,$unit2) = split(/:/,$unit);
      $LUSTRE_SVC_START = "\"$svc start $unit1;$svc start $unit2\"";
      $LUSTRE_SVC_STATUS = "$svc status $unit1";
      $LUSTRE_SVC_STOP = "\"$svc stop $unit2;$svc stop $unit1\"";
    } else {
      $LUSTRE_SVC_START = "$svc start $unit";
      $LUSTRE_SVC_STATUS = "$svc status $unit";
      $LUSTRE_SVC_STOP = "$svc stop $unit";
    }
  } else {
    $LUSTRE_SVC_START = "$cfg{LUSTRE_SVC} start";
    $LUSTRE_SVC_STATUS = "$cfg{LUSTRE_SVC} status";
    $LUSTRE_SVC_STOP = "$cfg{LUSTRE_SVC} stop";
  }

#===================   IP address arrays   ============================

  @IO_IB_IPS = split(/\n/,`for x in \`grep $cfg{IO_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | cut $cut_param_io | xargs\`\; do host \${x}-$cfg{IB_NIC} | grep address | sed 's/.*has address //'\;done`);

  @IO_CVLAN_IPS = split(/\n/,`for x in \`grep $cfg{IO_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | cut $cut_param_io | xargs\`\; do host \${x} | grep address | sed 's/.*has address //'\;done`);

  @IO_TENGIG_IPS = split(/\n/,`for x in \`grep $cfg{IO_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | cut $cut_param_io | xargs\`\; do host \${x}-$cfg{IO_CAMPUS_NIC} | grep address | sed 's/.*has address //'\;done`);

  @COMPUTE_IB_IPS = split(/\n/,`for x in \`grep $cfg{COMPUTE_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | cut $cut_param_comp | xargs\`\; do host \${x}-$cfg{IB_NIC} | grep address | sed 's/.*has address //'\;done`);

  @COMPUTE_CVLAN_IPS = split(/\n/,`for x in \`grep $cfg{COMPUTE_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | cut $cut_param_comp | xargs\`\; do host \${x} | grep address | sed 's/.*has address //'\;done`);

  if ($cfg{SECONDARY_NIC}) {
    @IO_SEC_IPS = split(/\n/,`for x in \`grep $cfg{IO_IMAGE} $nodes | grep $cfg{NODE_PREFIX} | cut $cut_param_io | xargs\`\; do host \${x}-$cfg{SECONDARY_NIC} | grep address | sed 's/.*has address //'\;done`);
  }

# verify IO node arrays have the correct number of entries

  if (scalar(@IO_IB_IPS) != $NUM_IO_NODES) {
    &syslog_write("info","$fname: CRITICAL Number of IO node IB IPs does not match NUM_IO_NODES");
  }
  if (scalar(@IO_CVLAN_IPS) != $NUM_IO_NODES) {
    &syslog_write("info","$fname: CRITICAL Number of IO node CVLAN IPs does not match NUM_IO_NODES");
  }
  if (scalar(@IO_TENGIG_IPS) != $NUM_IO_NODES) {
    &syslog_write("info","$fname: CRITICAL Number of IO node Ethernet IPs does not match NUM_IO_NODES");
  }

# array of IO gateways
# gw always one less than the broadcast

  my $i = 0;
  my $broadcast = "Bcast:\\|broadcast ";
  foreach my $ip (@IO_CVLAN_IPS) {
    my ($a,$b,$c,$d);
    my $gw = `$SSH_COMMAND $ip ifconfig $cfg{IO_CAMPUS_NIC} | grep "$broadcast" | sed 's/.*Bcast://' | sed 's/.*broadcast //' | sed 's/ .*//'`;
    chomp($gw);
    if (!($gw)) {
      &syslog_write("info","$fname: DGD initialization cannot access IO node $ip","");
    } else {
      ($a,$b,$c,$d) = split(/\./,$gw);
      $d--;
      $gw = "$a.$b.$c.$d";
      $TEMP_GWS[$i] = $gw;
    }
  }
  @IO_GW_IPS = uniq(@TEMP_GWS);

# array of lustre routes
# use a random set of backend nodes to populate route table
# then remove any duplicates

  my $rtrs=0;
  for ($c=0; $c<=$SAMPLE; $c++) {
    my $node = rand($NUM_COMP_NODES);
    @routes = split(/\n/,`$SSH_COMMAND $COMPUTE_CVLAN_IPS[$node - 1] lctl show_route | /bin/grep o2ib | /bin/grep up`);
    foreach $r (@routes) {
      ($net, $lnet, $hopkey, $hopval, $gw, $lnet_router, $junk) = split(/\s+/, $r);
      $TEMP_RTRS[$rtrs] = $lnet_router;
      $rtrs++;
    }
  }

  @LNET_RTRS = uniq(@TEMP_RTRS);
   
# Print the calculated array values if in debug mode

  if ($cfg{DEBUG}) {
    &syslog_write("info","$fname: Compute Range is $COMP_RANGE");
    &syslog_write("info","$fname: Sample size is $SAMPLE");
    &syslog_write("info","$fname: Compute Array includes");
    foreach $i (@CI) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    &syslog_write("info","$fname: IO IB IPs");
    foreach $i (@IO_IB_IPS) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    &syslog_write("info","$fname: IO Ethernet IPs");
    foreach $i (@IO_TENGIG_IPS) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    &syslog_write("info","$fname: IO CVlan IPs");
    foreach $i (@IO_CVLAN_IPS) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    &syslog_write("info","$fname: IO GW IPs");
    foreach $i (@IO_GW_IPS) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    &syslog_write("info","$fname: COMP IB IPs");
    foreach $i (@COMPUTE_IB_IPS) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    &syslog_write("info","$fname: COMP CVlan IPs");
    foreach $i (@COMPUTE_CVLAN_IPS) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    &syslog_write("info","$fname: LUSTRE Routers");
    foreach $i (@LNET_RTRS) { &syslog_write("info","$fname: $i"); }
    system("/usr/bin/sleep 5");
    if ($cfg{SECONDARY_NIC}) {
      &syslog_write("info","$fname: Secondary GW");
      foreach $i (@IO_SEC_IPS) { &syslog_write("info","$fname: $i"); }
      &syslog_write("info","$fname: Secondary IPs");
      foreach $i (@IO_SEC_IPS) { &syslog_write("info","$fname: $i"); }
    }
  }

}

#=========================================  

sub read_config {

  my $fname = "read_config";

  unless (open(CFG,"</etc/sysconfig/dgdcfg")) {
    &syslog_write("warning","$fname: DGD Error opening /etc/sysconfig/dgdcfg for READ: $!");
  }

  $cfg{COMPUTE_IMAGE} = "compute";
  $cfg{CUT_PARAM_IO} = 6;
  $cfg{CUT_PARAM_COMPUTE} = 6;
  $cfg{DEBUG} = 2;
  $cfg{IB_NIC} = "ib0";
  $cfg{IO_CAMPUS_NIC} = "bond0";
  $cfg{IO_IMAGE} = "io";
  $cfg{IOLOG_FILENAME} = "";
  $cfg{IOLOG_MSGS} = "";
  $cfg{LOCAL_CAMPUS_GW} = "1.2.3.4";
  $cfg{LUSTRE_SVC} = "";
  $cfg{MAX_FAIL} = 3;
  $cfg{MAX_PARTIAL_FAIL} = 5;
  $cfg{MAX_DEAD_IOS} = 5;
  $cfg{NODE_PREFIX} = "xx";
  $cfg{NUM_PING_PKTS} = 4;
  $cfg{PARALLEL_PEXEC} = "32";
  $cfg{PING_MAX} = 20;
  $cfg{PING_PERCENT} = .1;
  $cfg{PING_SIZE} = 56;
  $cfg{ROUTER_SVC} = "";
  $cfg{SANITY_CHECK} = 99;
  $cfg{SECONDARY_GW} = "";
  $cfg{SECONDARY_NIC} = "";
  $cfg{SKIP_FILENAME} = "";
  $cfg{SLEEP} = 2700;
  $cfg{SSH_TIMEOUT} = 10;
  $cfg{TIMEOUT_PEXEC} = "300";

# read in configuration file
# populate test array in order of execution
# if testing campus to IO nodes, insert test to verify campus gw

  my $tc=0;
  while (<CFG>) {
    if (!(/^#/ || !(/\w/))) {
      chomp;
      ($k,$v) = split(/ /,$_,2);
      if ($k =~ /^TEST/ && $v == 1) {
        if ($k eq "TEST_CAMPUS_TO_IO_ETH") {
           $TESTS[$tc] = "TEST_CAMPUS_TO_ETH_GW";
           $tc++;
        }
        $TESTS[$tc] = $k;
        $tc++;
      } else {
         $cfg{$k} = $v;
      }
      if ($cfg{DEBUG}) { &syslog_write("info","$fname: Configuration: $k = $v"); }
    }
  }

# Handle multiple images
  $COMP_RANGE = "";
  if ($cfg{COMPUTE_IMAGE} =~ /:/) {
    @CI = split(/:/,$cfg{COMPUTE_IMAGE});
    $cfg{COMPUTE_IMAGE} = "";
    foreach $ci (@CI) {
     $cfg{COMPUTE_IMAGE} .= $ci."\\|";
     $COMP_RANGE .= "\@$ci,";
    }
    $cfg{COMPUTE_IMAGE} = substr($cfg{COMPUTE_IMAGE},0, length($cfg{COMPUTE_IMAGE}) -2);
    $cfg{COMPUTE_IMAGE} = "\"".$cfg{COMPUTE_IMAGE}."\"";
    $COMP_RANGE = substr($COMP_RANGE,0, length($COMP_RANGE) -1);
  }

# set number of tests global variable

  $NUMTESTS = $tc;

}

#=========================================  

sub uniq {
    no strict;
    my %seen;
    grep !$seen{$_}++, @_;
}

#=========================================  

sub check_status {

    $r = `/bin/ps -ef | /bin/grep dgd | /bin/grep -v grep | /usr/bin/wc -l`;
    chomp($r);
    if ($r >= 2) {
      &syslog_write("warning","$fname: DGD daemon already running - FAIL");
    }
}

#=========================================  

sub syslog_write {
    my($type,$msg) = @_;

    my $title = "DeadGatewayDetection";

    if ($type eq "warning") { $msg .= " Exiting!"; }

    openlog("$title", 'cons,pid', 'user');
    syslog("$type", "$msg");
    closelog();

    if ($type eq "warning") {
      exit;
    }
}

1;

