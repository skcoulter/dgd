#!/usr/bin/perl -w
#
# Dead Gateway Detection
#
# Loosely based on an idea from HB Chen
# Author: Susan Coulter
# 
# Description:  Monitors the IO nodes of a cluster, discovered
#     dynamically via xcat/perceus config files, etc.  Four 
#     components, (IB, 10G, OSPF, GW access) are monitored.
#     Successive failures of any one component cause the IO to 
#     be considered INACTIVE and that IO node is taken out, or 
#     replaced, in the compute node routes.
#
# Update History 
#     03/10/2008  - run with BlueSteel's Panasas 
#     05/28/2008  - Susan Coulter
#     05/28/2008    removed static variables to dgdh.pl
#                   cleaned up and modularized the code
#     01/07/2010  - Susan Coulter
#                   changed dgdh.pl to dgd_init.pm
#		    using logic to set variables instead of hardcode
#		    added more abstraction
#                   simplified the logic
#                   added use of multi-dimensional arrays
#     30/06/2010  - Susan Coulter
#                   Modified route change logic (RedTail)
#     01/11/2011 -  skc
#	            Modified route change logic for RoadRunner
#     04/15/2011 -  skc
#                   Implemented changes suggested during code review
#                     plus additional improvements and abstractions
#     04/16/2012 - skc
#                  Verify campus connectivity
#                  Tests driven by configuration file
#                  Check OSPF status matches IO status
#                  Cleanup and streamline
#     10/02/2012 - skc
#                  Added ConnectTimeout to ssh 
#                  Verfied nsm state line found (related to ssh timeout)
#                  Removed special hurricane stuff (never used)
#                  Added special cerrillos init variables
#     06/10/2013 - skc
#		   Moved ssh timeout to config with default of 10 seconds
#		   Began adding iolog test
#     08/20/2013 - jmartinez
#                  Added code to handle IO LOG Health Checking
#                  Added code to check for DST
#     01/07/2016 - skc
#                  Implement changes associated with:
#                  Ordering tests as driven by config file
#                  Accepting signals to change processing 
#                  Lustre
#     04/18/2017 - skc
#     	           Fixed iolog logic and a few syslog messages
#		   
#     08/01/2017 - skc
#     		   Added stop of LNet service
#     		   Added timeout capability on pexec
#     		   Changed some message text and syslog_write call		

use strict;
use warnings;
unshift (@INC, "/usr/sbin");
require "dgd_init.pm";

# Modules needed for syslog and daemon-ness
use POSIX;
use Sys::Syslog;
use Time::Local;

#===========================================================================
#======================  start of mainline  ================================
#===========================================================================

&daemonize;

$SIG{HUP} = \&re_config_signal_handler;
$SIG{INT} = \&wake_up_signal_handler;
$SIG{USR1} = \&suspend_signal_handler;
$SIG{USR2} = \&dump_health_handler;
 
our $ACTIVE;
our $COMP_RANGE;
our $ETHCFG_REDO;
our $ETHCFG_SVC_START;
our $FAILED_IOLOG_FILENAME;
our $INACTIVE;
our $INACTIVE_COMPLETE;
our $INACTIVE_PARTIAL;
our $INSANE;
our $IO_RANGE;
our $LUSTRE_SVC_START;
our $LUSTRE_SVC_STATUS;
our $LUSTRE_SVC_STOP;
our $NUMTESTS;
our $NUM_COMP_NODES;
our $NUM_DEAD_IOS;
our $NUM_IO_NODES;
our $SAMPLE;
our $SLEEPING;
our $SSH_COMMAND;

our @CI;
our @COMPUTE_CVLAN_IPS;
our @II;
our @IOLOG_Health;
our @IO_CVLAN_IPS;
our @IO_GW_IPS;
our @IO_IB_IPS;
our @IO_Node_Health;
our @IO_SEC_IPS;
our @IO_TENGIG_IPS;
our @LNET_RTRS;
our @OSPF_Health;
our @SEC_GW;
our @SN_GW;
our @STAT;
our @TESTS;

our %AL;
our %cfg;
our %FN;
our %GW_Health;
our %IB_Health;
our %LU_Health;
our %SEC_Health;
our %SECGW_Health;
our %SNcampus_Health;
our %TenGig_Health;

my $fname = "main";

#=====================================================

$SLEEPING = 0;

&set_environment;

&initialize;

&syslog_write("info","$fname: Starting DGD");

while ( 1 )  {

   ##
   # Run DGD code if cluster not on DST
   ## 

   if ( (-e $cfg{SKIP_FILENAME}) || (-e $INSANE) ) {
      &syslog_write("info","$fname: DST or other actions underway, tests skipped, sleeping $cfg{SLEEP} seconds");
   } else { 
      &syslog_write("info","$fname: Start Loop");

      &run_tests;

      &syslog_write("info","$fname: End Loop, sleep $cfg{SLEEP} seconds");
   }

   $SLEEPING = 1;
   sleep $cfg{SLEEP};
   $SLEEPING = 0;
 }

 &syslog_write("warning","$fname: DGD Perl script ended - kind of unusual");

#===========================================================================
#====================  end of mainline  ====================================
#===========================================================================

#============================
# initialize health arrays
#============================

sub initialize {
    my $fname = "initialize";
    my $i;

# campus connection

    $SNcampus_Health{$cfg{LOCAL_CAMPUS_GW}}->{FAIL} = 0;
    $SNcampus_Health{$cfg{LOCAL_CAMPUS_GW}}->{DGRD} = 0;
    $SNcampus_Health{$cfg{LOCAL_CAMPUS_GW}}->{STAT} = $ACTIVE;

# secondary gateway
 
    $SECGW_Health{$cfg{SECONDARY_GW}}->{FAIL} = 0;
    $SECGW_Health{$cfg{SECONDARY_GW}}->{DGRD} = 0;
    $SECGW_Health{$cfg{SECONDARY_GW}}->{STAT} = $ACTIVE;
    $SECGW_Health{$cfg{SECONDARY_GW}}->{HLTH} = $ACTIVE;

# lustre routers

    my $num_lnet_rtrs = @LNET_RTRS;
    for ($i=0; $i<=$num_lnet_rtrs; $i++) {
      $LU_Health{$LNET_RTRS[$i]}->{FAIL} = 0;
      $LU_Health{$LNET_RTRS[$i]}->{DGRD} = 0;
      $LU_Health{$LNET_RTRS[$i]}->{STAT} = $ACTIVE;
      $LU_Health{$LNET_RTRS[$i]}->{HLTH} = $ACTIVE;
    }

# gateways

    my $num_gws = @IO_GW_IPS;
    for ($i=0; $i<=$num_gws; $i++) {
      $GW_Health{$IO_GW_IPS[$i]}->{FAIL} = 0;
      $GW_Health{$IO_GW_IPS[$i]}->{DGRD} = 0;
      $GW_Health{$IO_GW_IPS[$i]}->{STAT} = $ACTIVE;
      $GW_Health{$IO_GW_IPS[$i]}->{HLTH} = $ACTIVE;
    }

# IO NICs, OSPF, IOLOG and IO Node status

    for ($i=0; $i <= $NUM_IO_NODES-1; $i++) {
      $IB_Health{$IO_IB_IPS[$i]}->{FAIL} = 0;
      $IB_Health{$IO_IB_IPS[$i]}->{DGRD} = 0;
      $IB_Health{$IO_IB_IPS[$i]}->{STAT} = $ACTIVE;

      $TenGig_Health{$IO_TENGIG_IPS[$i]}->{FAIL} = 0;
      $TenGig_Health{$IO_TENGIG_IPS[$i]}->{DGRD} = 0;
      $TenGig_Health{$IO_TENGIG_IPS[$i]}->{STAT} = $ACTIVE;

      $SEC_Health{$IO_SEC_IPS[$i]}->{FAIL} = 0;
      $SEC_Health{$IO_SEC_IPS[$i]}->{DGRD} = 0;
      $SEC_Health{$IO_SEC_IPS[$i]}->{STAT} = $ACTIVE;

      $OSPF_Health[$i] = $ACTIVE;
      $IOLOG_Health[$i] = $ACTIVE;

      $IO_Node_Health[$i] = $ACTIVE;
    }

# set the array of arguments for the tests

    @{$AL{TEST_COMPUTE_TO_LUSTRE}} = ('COMPUTE_TO_LUSTRE',\%LU_Health,@LNET_RTRS);
    @{$AL{TEST_COMPUTE_TO_SWITCH_GW}} = ('COMPUTE_TO_SWITCH_GW',\%GW_Health,@IO_GW_IPS);
    @{$AL{TEST_IO_NODE_DMESG}} = ('');
    @{$AL{TEST_IO_NODE_NETSTAT}} = ('');
    @{$AL{TEST_IO_NODE_LOG}} = ('');
    @{$AL{TEST_IO_NODE_TO_CAMPUS}} = ('');
    @{$AL{TEST_OSPF_LOGS}} = ('');
    @{$AL{TEST_CAMPUS_TO_ETH_GW}} = ('CAMPUS_TO_ETH_GW',\%SNcampus_Health,@SN_GW);
    @{$AL{TEST_CAMPUS_TO_IO_ETH}} = ('CAMPUS_TO_IO_ETH',\%TenGig_Health,@IO_TENGIG_IPS);
    @{$AL{TEST_INTERNAL_TO_IO_IB}} = ('INTERNAL_TO_IO_IB',\%IB_Health,@IO_IB_IPS);
    @{$AL{TEST_COMPUTE_TO_SEC}} = ('COMPUTE_TO_SEC',\%SEC_Health,@IO_SEC_IPS);
    @{$AL{TEST_COMPUTE_TO_SEC_GW}} = ('COMPUTE_TO_SEC_GW',\%SECGW_Health,@SEC_GW);

}

#=============================================
# check the health of the network subsystem
#=============================================

sub run_tests {
  my $fname = "run_tests";
  my ($cvlan_ping,$node,$test);

# use array of functions to run in configuration defined order
# check status between each set of tests

  for ($test=0; $test<$NUMTESTS; $test++) {

    if ($cfg{DEBUG}) {
      &syslog_write("info","$fname: >>> Test is $TESTS[$test]");
    }

# functions called multiple times with calculated arguments
#    add ssh command to the first element of the argument list array

     if ($TESTS[$test] =~ /TEST_COMPUTE_TO/) {

        my $c;
        my $base_parm = $AL{$TESTS[$test]}[0];
        for ($c=0; $c<$SAMPLE; $c++) {
          my $node = rand($NUM_COMP_NODES);
          my $cvlan_ping = "$SSH_COMMAND $COMPUTE_CVLAN_IPS[$node - 1] ";
          $AL{$TESTS[$test]}[0] = $base_parm.$cvlan_ping;
          $FN{$TESTS[$test]}->(@{$AL{$TESTS[$test]}});
        }
        $AL{$TESTS[$test]}[0] = $base_parm;
        &reset_counters(@{$AL{$TESTS[$test]}});
   
# functions with simple/no arguments

     } else {
     
         $FN{$TESTS[$test]}->(@{$AL{$TESTS[$test]}});
     }

     &check_for_state_change(0);

# if sanity threshold crossed - stop testing
#
     if (-e $INSANE) { $test = $NUMTESTS+1; }

  } 

  &check_for_state_change(1);

}


#============================
# check for state change
#============================

sub check_for_state_change {

  my $fname = "check_for_state_change";
  my $all_tests_complete = $_[0];
  my $route_mods=0;
  my @sanity = ();
  my ($i,$msg,$n,$num_gws,$num_lnet_rtrs);

  if ($cfg{DEBUG}) {
    &syslog_write("info","$fname: Checking health hashes and state changes");
  }

# Loop thru all the IO nodes checking status

  for ($i=0; $i <= $NUM_IO_NODES-1; $i++) {

    $n = `host $IO_CVLAN_IPS[$i] | sed 's/.*name pointer //' | sed 's/\\..*//'`;
    chomp($n);

    if ($cfg{DEBUG}) {
      &syslog_write("info","$fname: Index is $i, hostname is $n, IB_IP is $IO_IB_IPS[$i], IO node health is $IO_Node_Health[$i]");
    }

    if ($IB_Health{$IO_IB_IPS[$i]}->{STAT} == $ACTIVE        &&
       $TenGig_Health{$IO_TENGIG_IPS[$i]}->{STAT} == $ACTIVE &&
       $OSPF_Health[$i] == $ACTIVE		             &&
       $IOLOG_Health[$i] == $ACTIVE) {

# if this IO node was previously INACTIVE                      
#    something on the IO node was fixed 
#    verify state of ospf and IB interface
#    increment route mod counter 

      if ($IO_Node_Health[$i] == $INACTIVE) {
        $IO_Node_Health[$i] = $ACTIVE;
        $msg = "$fname: CRITICAL - IO Node $n has changed to ACTIVE";
        &syslog_write("info", $msg, "");
        $NUM_DEAD_IOS--;
        $route_mods++;
        &verify_node_state($i, 1);
      }
    } else {

# if this IO node was previously ACTIVE, something on the IO node is broken 
#    mark it as down,increment dead io counter, write details to syslog 
#    take appropriate actions on the node, set sanity and increment route mod counter

      if ($IO_Node_Health[$i] == $ACTIVE) {
        $IO_Node_Health[$i] = $INACTIVE;
        $NUM_DEAD_IOS++;
        $msg = "$fname: CRITICAL - IO Node $n has changed to INACTIVE. Status details are ";
        $msg .= "IB/$STAT[$IB_Health{$IO_IB_IPS[$i]}->{STAT}], ";
        $msg .= "10G/$STAT[$TenGig_Health{$IO_TENGIG_IPS[$i]}->{STAT}], ";
        $msg .= "GW/$STAT[$GW_Health{$IO_GW_IPS[$i]}->{STAT}], ";
        $msg .= "OSPF/$STAT[$OSPF_Health[$i]], ";
        $msg .= "IOLOG/$STAT[$IOLOG_Health[$i]] ";
        if ($cfg{SECONDARY_NIC}) {
          $msg .= "SECONDARY/$STAT[$SEC_Health{$IO_SEC_IPS[$i]}->{STAT}]";
        }
        &syslog_write("info", $msg);
        &node_down($i);
        $sanity[$i] = 1;
        $route_mods++;
      }
      
# write status message
# verify state after all tests complete

      if ($all_tests_complete) { 
         &verify_node_state($i, 0);
         $msg = "$fname: Status of IO Node $n is INACTIVE";
         &syslog_write("info", $msg, "");
      }
    }
  }

# if the number of dead IO nodes exceeds the sanity check
#   un-do the node_down actions,               
#   re-initialize health arrays and send a message
#   something whacky is going on

  if ($route_mods >= $cfg{SANITY_CHECK}) {
     $route_mods = 0;
     &syslog_write("info", "$fname: CRITICAL - Sanity threshold of $cfg{SANITY_CHECK} exceeded", "");
     for ($i=0; $i <= $NUM_IO_NODES-1; $i++) {     
       if ($sanity[$i]) {
          $NUM_DEAD_IOS--;
          &verify_node_state($i ,1);
       }
     }
     &initialize;
     system("/bin/touch $INSANE");
     &syslog_write("info", "$fname: CRITICAL - $INSANE created, Mitigation undone, testing paused, please check the cluster", "");
  }

# if total number of IO nodes Dead is over the threshold
#   send an email to alert that performance could be affected

  if ($NUM_DEAD_IOS >= $cfg{MAX_DEAD_IOS}) {
     &syslog_write("info", "$fname: CRITICAL - $cfg{MAX_DEAD_IOS} or more IO nodes are now INACTIVE", "");
  }

# if nodes changed state, reset the routes

  if ($route_mods > 0) {
     &syslog_write("info","$fname: IO status changed, routes being modified: $ETHCFG_REDO");
     system("$ETHCFG_REDO");
  }

# only after all tests are complete ...
#   report failures/fixes for gateways

  if ($all_tests_complete) {
    $num_gws = @IO_GW_IPS;
    for ($i=0; $i < $num_gws; $i++) {
      if ($GW_Health{$IO_GW_IPS[$i]}->{STAT} > 0) {
        $GW_Health{$IO_GW_IPS[$i]}->{HLTH} = $INACTIVE;
        $msg = "$fname: CRITICAL - ping failed to GW $IO_GW_IPS[$i] - $STAT[$GW_Health{$IO_GW_IPS[$i]}->{STAT}] ";
        &syslog_write("info", $msg, "");
      } else {
        if ($GW_Health{$IO_GW_IPS[$i]}->{HLTH} == $INACTIVE) {
          $GW_Health{$IO_GW_IPS[$i]}->{HLTH} = $ACTIVE;
          $msg = "$fname: CRITICAL - previously failed ping now successful to GW $IO_GW_IPS[$i]";
          &syslog_write("info", $msg, "");
        }
      }
    }

#   report failures/fixes for secondary gateway

    if ($SECGW_Health{$cfg{SECONDARY_GW}}->{STAT} > 0) {
      $SECGW_Health{$cfg{SECONDARY_GW}}->{HLTH} = $INACTIVE;
      $msg = "$fname: CRITICAL - ping failed to SEC GW $cfg{SECONDARY_GW}";
      &syslog_write("info", $msg, "");
    } else {
      if ($SECGW_Health{$cfg{SECONDARY_GW}}->{HLTH} == $INACTIVE) {
        $SECGW_Health{$cfg{SECONDARY_GW}}->{HLTH} = $ACTIVE;
        $msg = "$fname: CRITICAL - previously failed ping now successful to SECGW $cfg{SECONDARY_GW}";
        &syslog_write("info", $msg, "");
      }
    }

#   report failures/fixes for LNet routers

    $num_lnet_rtrs = @LNET_RTRS;
    for ($i=0; $i < $num_lnet_rtrs; $i++) {
       if ($LU_Health{$LNET_RTRS[$i]}->{STAT} == $INACTIVE) {
         $LU_Health{$LNET_RTRS[$i]}->{HLTH} = $INACTIVE;
         $msg = "$fname: CRITICAL - lctl ping failed to LNet Router $LNET_RTRS[$i]";
         &syslog_write("info", $msg, "");
       } else {
         if ($LU_Health{$LNET_RTRS[$i]}->{HLTH} == $INACTIVE) {
           $LU_Health{$LNET_RTRS[$i]}->{HLTH} = $ACTIVE;
           $msg = "$fname: CRITICAL - previously failed lctl ping now successful to LNet Router $LNET_RTRS[$i]";
           &syslog_write("info", $msg, "");
         }
      }
    }
  }
}   

#============================
#  ping tests
#============================

sub check_connectivity {
  my $fname = "check_connectivity";
  my ($key,$hash_ref,@ips) = @_; 
  my $c = 0;
  my ($cmd, $list, $mf, $mpf, $reset, $tst);
 
  if ($cfg{DEBUG}) {
   &syslog_write("info", "$fname: running test $key");
  }

# default max failure levels

  $mf = $cfg{MAX_FAIL}; 
  $mpf = $cfg{MAX_PARTIAL_FAIL}; 

# If this is the campus test, insure the GW test succeeded

  if ($key eq "CAMPUS_TO_IO_ETH") {
      if (!($SNcampus_Health{$cfg{LOCAL_CAMPUS_GW}}->{STAT} == $ACTIVE)) {
        &syslog_write("info", "$fname: CRITICAL No Campus Connectivity - Ethernet Test Skipped","");
        return;
      }
  }

#---------------------------------------
# setup command depending on the test
#---------------------------------------

# campus and internal pings done from the master
#    if GW test, one failure is the max
#    ( no GW - no way to test IO via campus )
 
  if ($key =~ /^CAMPUS/) {
    $cmd = "/bin/ping";
    $reset = 1;
    if ($key =~ /GW/) {
      $mf = 1;
      $mpf = 1;
    }

  } elsif ($key eq "INTERNAL_TO_IO_IB") {
    $cmd = "/bin/ping -I $cfg{IB_NIC}";
    $reset = 1;

# compute pings done via the cvlan using SSH
#   SSH command and IP extracted from the key
#   thresholds tied to number of nodes tested from
#   lustre pings need the lctl command
#   the rest use typical ping
   
  } elsif ($key =~ /^COMPUTE/) {

    $reset = 0;
    $cmd = "";
    ($tst,$cmd) = split(/\//, $key, 2);
    $cmd = "/".$cmd;
    $mf = ($SAMPLE * .5) + 1;
    $mpf = ($SAMPLE * .75) + 1;; 

    if ($key =~ /LUSTRE/) {
      $cmd .= "/usr/sbin/lctl ping ";
    } else {
      $cmd .= "/bin/ping";
    }
  } else {
    &syslog_write("warning","$fname: Empty or unknown argument value for key");
  }

#-------------------------------------------------------------------
# execute command and interpret results depending on ICMP vs LCTL
#    tests from compute nodes are not reset here
#-------------------------------------------------------------------

# LCTL

  if ($cmd =~ /lctl/) {

    while ($ips[$c]) {

      if ($cfg{DEBUG}) {
        &syslog_write("info", "$fname: $cmd $ips[$c]");
      }

      my $r = `$cmd $ips[$c] 2>&1`;

# Failure
      if ($r =~ /failed/) {
        $hash_ref->{$ips[$c]}->{FAIL}++;
        &syslog_write("info", "$fname: FAIL lctl ping count for $ips[$c] is $hash_ref->{$ips[$c]}->{FAIL}, Maximum consecutive allowed is $mf");
        if ($hash_ref->{$ips[$c]}->{FAIL} >= $mf) {
          $hash_ref->{$ips[$c]}->{STAT} = $INACTIVE;
        }
      }
      $c++;
    }

# ICMP

  } else {

    while ($ips[$c]) {

      if ($cfg{DEBUG}) {
        &syslog_write("info", "$fname: $cmd -c $cfg{NUM_PING_PKTS} -w $cfg{NUM_PING_PKTS} -s $cfg{PING_SIZE} $ips[$c]");
      }

      my $r = `$cmd -c $cfg{NUM_PING_PKTS} -w $cfg{NUM_PING_PKTS} -s $cfg{PING_SIZE} $ips[$c]`;

      my $packet_lost_rate = &check_ping_results($r);

# 100% packet loss
      if ($packet_lost_rate == 100) {
        $hash_ref->{$ips[$c]}->{FAIL}++;
        &syslog_write("info", "$fname: FAIL ping fail count for $ips[$c], index $c, is $hash_ref->{$ips[$c]}->{FAIL}, Maximum consecutive allowed is $mf");
        if ($hash_ref->{$ips[$c]}->{FAIL} >= $mf) {
          $hash_ref->{$ips[$c]}->{STAT} = $INACTIVE_COMPLETE;
          &syslog_write("info", "$fname: FAIL ping fail count for $ips[$c], index $c, exceeds maximum, setting to INACTIVE_COMPLETE");
        }
# Partial packet loss
      } elsif ($packet_lost_rate != 0) {
        $hash_ref->{$ips[$c]}->{DGRD}++;
        &syslog_write("info", "$fname: FAIL ping degraded count for $ips[$c], index $c, is $hash_ref->{$ips[$c]}->{DGRD}, Maximum consecutive allowed is $mpf");
        if ($hash_ref->{$ips[$c]}->{DGRD} >= $mpf) {
          $hash_ref->{$ips[$c]}->{STAT} = $INACTIVE_PARTIAL;
          &syslog_write("info", "$fname: FAIL ping degraded count for $ips[$c], index $c, exceeds maximum, setting to INACTIVE_PARTIAL");
        }
      } else {
        if ($reset) { 
          $hash_ref->{$ips[$c]}->{STAT} = $ACTIVE;
          $hash_ref->{$ips[$c]}->{DGRD} = 0;
          $hash_ref->{$ips[$c]}->{FAIL} = 0;
        }
      }
      $c++;
    }
  }
}

#============================
# check neighbor status
#============================

sub check_ospf {
  my $fname = "check_ospf";
  my $c = 0;
  my $nsm_found = 0;
  my $cmd;
  my @r;

  while ($IO_CVLAN_IPS[$c]) {

    $cmd = "$SSH_COMMAND $IO_CVLAN_IPS[$c] tac /var/log/quagga/ospfd.log";

    if ($cfg{DEBUG}) {
      &syslog_write("info", "$fname: cmd is $cmd");
    }

    @r = split(/\n/,`$cmd`);

    $nsm_found = 0;
    foreach my $l (@r) {
      if ($l =~ /nsm_change_state/) {
        $nsm_found = 1;
        if ($l =~ / -> Full/) {
          $OSPF_Health[$c] = $ACTIVE;
        } else {
          $OSPF_Health[$c] = $INACTIVE;
        }
        last;
      }
    }

# no state entry or unable to ssh to IO node
    if (!$nsm_found) { $OSPF_Health[$c] = $INACTIVE; }

    $c++;
  }

}

#============================
# check iolog
#============================

sub check_iolog {
    my $fname = "check_iolog";
    my ($cnt,$key,$i,$ionode,$limit,$msg,$value);
    my @limits;
    my @r;
    my %iolog_limits;

    if ($cfg{DEBUG}) {
      &syslog_write("info", "$fname: checking for file $cfg{IOLOG_FILENAME}");
    }
 
# assume all nodes pass this test
#   this resets previous failures

    for ($i=0; $i <= $NUM_IO_NODES-1; $i++) {
      $IOLOG_Health[$i] = $ACTIVE;
    }

# if dgd log exists, analyze it
    if ( -e $cfg{IOLOG_FILENAME} ) {

      @limits = split(/,/,$cfg{IOLOG_MSGS});
      foreach (@limits) {
         ($key,$value) = split(/::/,$_);
         $iolog_limits{$key} = $value;
      }

      while (($msg,$limit) = each(%iolog_limits)) {
        &syslog_write("info", "$fname: looking for message $msg with limit $limit");
        @r = `/bin/grep "$msg" $cfg{IOLOG_FILENAME} | /bin/awk '{print \$4}' | /bin/sort | /usr/bin/uniq -c`;
        foreach (@r) {
	   $_ =~ s/^\s+//;
           ($cnt, $ionode) = split(/\s+/,$_);
           if ($cnt >= $limit) {
              &iolog_limit_exceeded($ionode, $msg);
           }
         }
      }

      system("/bin/mv -f $cfg{IOLOG_FILENAME} $FAILED_IOLOG_FILENAME");
  }

}


#==================================================
# process iolog errors that exceed the threshold
#==================================================
   
sub iolog_limit_exceeded {

    my $fname = "iolog_limit_exceeded";
    my ($node,$msg) = @_;
    my ($i,$ipaddress);

    $ipaddress = `/usr/bin/host $node | /bin/sed -r 's/.*address //g'`;
    chomp($ipaddress);

    # find correct array key
    $i=0;
    foreach (@IO_CVLAN_IPS) {
      if ($_ =~ /$ipaddress/) {
        last;
      }
      $i++;
    }

   $IOLOG_Health[$i] = $INACTIVE;

    if ($cfg{DEBUG}) {
      &syslog_write("info", "$fname: $node $ipaddress seen as inactive");
    }
}

#============================
# set IO node to down state
#============================

sub node_down {

   my $fname = "node_down";
   my $num = $_[0];

  if ($cfg{DEBUG}) {
     &syslog_write("info", "$fname: IO node has gone INACTIVE");
     &syslog_write("info", "$fname: IB ip is $IO_IB_IPS[$num]");
     &syslog_write("info", "$fname: TenG ip is $IO_TENGIG_IPS[$num]");
  }

  if ($cfg{DEBUG} < 2) {
    system("$SSH_COMMAND $IO_CVLAN_IPS[$num] $cfg{ROUTER_SVC} stop");
    system("$SSH_COMMAND $IO_CVLAN_IPS[$num] ifconfig $cfg{IB_NIC} down");
    if ($cfg{LUSTRE_SVC} ) {
      system("$SSH_COMMAND $IO_CVLAN_IPS[$num] $LUSTRE_SVC_STOP");
    }
  }

# set IB and OSPF indicators to INACTIVE to appropriately reflect the state
#   (Lustre problems do not cause removal of the gateway node)

 $IB_Health{$IO_IB_IPS[$num]}->{STAT} = $INACTIVE;
 $OSPF_Health[$num] = $INACTIVE;

}

#==============================================================
# verify the character of the node matches the current state
#==============================================================

sub verify_node_state {

   my $fname = "verify_node_state";
   my ($num,$state) = @_;
   my @grep = ("stopped\\|Active: inactive","running\\|Active: active");
   my @action = ("stop","start");
   my ($cmd,$r);

# OSPF

  $r = "";
  $cmd = "$SSH_COMMAND $IO_CVLAN_IPS[$num] $cfg{ROUTER_SVC} status | grep \"$grep[$state]\"";

  if ($cfg{DEBUG}) {
     &syslog_write("info", "$fname: Checking status of ospf: $cmd");
  }

  $r = `$cmd`;

  if ($cfg{DEBUG} < 2 && !($r)) {
    $cmd = "$SSH_COMMAND $IO_CVLAN_IPS[$num] $cfg{ROUTER_SVC} $action[$state]";
    system($cmd);
  }

  if ($cfg{DEBUG} && !($r)) {
    &syslog_write("info","$fname: $cfg{ROUTER_SVC} status did not match state of IO node - fixed");
    &syslog_write("info","$fname: $cmd");
  }

# LUSTRE

  $r = "";
  if ($cfg{LUSTRE_SVC}) {

    $cmd = "$SSH_COMMAND $IO_CVLAN_IPS[$num] $LUSTRE_SVC_STATUS | grep \"$grep[$state]\"";

    if ($cfg{DEBUG}) {
       &syslog_write("info", "$fname: Checking status of lustre: $cmd");
    }

    $r = `$cmd`;

    if ($cfg{DEBUG} < 2 && !($r)) {
      if ($action[$state] eq "stop") {
        $cmd = "$SSH_COMMAND $IO_CVLAN_IPS[$num] $LUSTRE_SVC_STOP";
      } else {
        $cmd = "$SSH_COMMAND $IO_CVLAN_IPS[$num] $LUSTRE_SVC_START";
      }
      system($cmd);
    }

    if ($cfg{DEBUG} && !($r)) {
      &syslog_write("info","$fname: $cfg{LUSTRE_SVC} status did not match state of IO node - fixed");
      &syslog_write("info","$fname: $cmd");
    }
  }

# IB
 
  if ($cfg{DEBUG}) {
      &syslog_write("info", "$fname: Verifying status of IB HCA");
  }

  if ($cfg{DEBUG} < 2 && $state == 0) {
    system("$SSH_COMMAND $IO_CVLAN_IPS[$num] ifconfig $cfg{IB_NIC} down");
  }

  if ($cfg{DEBUG} < 2 && $state == 1) {
    system("$SSH_COMMAND $IO_CVLAN_IPS[$num] $ETHCFG_SVC_START");
  }
}

#============================
# checks ping results
#============================

sub check_ping_results {

    my $fname = "check_ping_results";
    my $r = $_[0];

    my @ib_ping_result = split(/\n/,$r);
    my $packet_lost_rate = 0;
    foreach my $ibline (@ib_ping_result) {
      if($ibline =~ /transmitted/) {
         # 4 packets transmitted, 4 received, 0% packet loss, time 3007ms
         # 4 packets transmitted, 2 received, 50% packet loss, time 3007ms
         if ($ibline =~ /100% packet loss/) {
           $packet_lost_rate = 100;
         }
         elsif (!($ibline =~ / 0% packet loss/)) {
           $ibline =~ / received, (\d+)% packet loss/;
           $packet_lost_rate = $1;
         }
      }
    }

    return $packet_lost_rate;

}

#====================================================
# reset counters for tests from random compute set
#====================================================

sub reset_counters {

  my $fname = "reset_counters";
  my ($key,$hash_ref,@ips) = @_; 
  my $c = 0;
 
  if ($cfg{DEBUG}) {
    &syslog_write("info", "$fname: resetting counters for $key test");
  }

  while ($ips[$c]) {
    if ($hash_ref->{$ips[$c]}->{STAT} > 0  && 
        $hash_ref->{$ips[$c]}->{FAIL} == 0 &&
        $hash_ref->{$ips[$c]}->{DGRD} == 0 ) {
      $hash_ref->{$ips[$c]}->{STAT} = $ACTIVE;
    }
    $hash_ref->{$ips[$c]}->{FAIL} = 0;
    $hash_ref->{$ips[$c]}->{DGRD} = 0;
    $c++;
  }
} 

#================================
# placeholder for future tests
#================================

sub future {

  my $fname = "future";

  if ($cfg{DEBUG}) {
      &syslog_write("info", "$fname: This test is not implemented yet");
  }

}

#===============================================
# handle signal to restart tests
#    for safety, only done when in sleep mode  
#===============================================

sub wake_up_signal_handler {
 
    my $fname = "wake_up_signal_handler";

    if ($SLEEPING) {
      &syslog_write("info","$fname: SLEEPING: Caught INT signal - waking up and restarting tests");
      $SLEEPING=0;
      run_tests();
    } else {
      &syslog_write("info","$fname: NOT SLEEPING: Caught INT signal - ignoring");
    } 

}

#==========================================
# handle signal to suspend
#    regardless of state, forces a sleep
#==========================================

sub suspend_signal_handler {
 
    my $fname = "suspend_signal_handler";

    &syslog_write("info","$fname: Caught USR1 signal - sleeping for $cfg{SLEEP}");
    $SLEEPING=1;
    sleep $cfg{SLEEP};
    $SLEEPING=0;

}

#===================================================
# handle signal to re-read the configuration file
#    for safety, only done when in sleep mode
#===================================================

sub re_config_signal_handler {

    my $fname = "re_config_signal_handler";

    if ($SLEEPING) {
      &syslog_write("info","$fname: SLEEPING: Caught HUP signal - waking up and rereading the config file");
      $SLEEPING=0;
      read_config();
    } else {
      &syslog_write("info","$fname: NOT SLEEPING: Caught HUP signal - ignoring");
    }

}

#===================================================
# handle signal to dump the current health status
#===================================================

sub dump_health_handler {

    my $fname = "dump_health_handler";
    my $i;

    &syslog_write("info","$fname: Caught USR2 signal, DUMPING HEALTH STATUS");

# dump campus connection status

    &syslog_write("info","$fname: Health status of the campus gateway is $STAT[$SNcampus_Health{$cfg{LOCAL_CAMPUS_GW}}->{STAT}]");

# dump gateway status
 
  foreach $i (@IO_GW_IPS) {
    &syslog_write("info","$fname: Health of gateway $i is $STAT[$GW_Health{$IO_GW_IPS[$i]}->{STAT}]");
  }

# dump secondary gateway status

    foreach $i (@SEC_GW) {
      &syslog_write("info","$fname: Health of secondary gateway $SEC_GW[$i] is $STAT[$SECGW_Health{$SEC_GW[$i]}->{STAT}]");
    }

# dump lustre router satus

    foreach $i (@LNET_RTRS) {
      &syslog_write("info","$fname: Fail count for LNet Router $LNET_RTRS[$i] is $LU_Health{$LNET_RTRS[$i]}->{FAIL}");
      &syslog_write("info","$fname: Degrade count for LNet Router $LNET_RTRS[$i] is $LU_Health{$LNET_RTRS[$i]}->{DGRD}");
    }

# dump IO NICs, OSPF, IOLOG and IO Node status

    for ($i=0; $i <= $NUM_IO_NODES-1; $i++) {
      &syslog_write("info","$fname: Fail count for IB interface $IO_IB_IPS[$i] is $IB_Health{$IO_IB_IPS[$i]}->{FAIL}");
      &syslog_write("info","$fname: Degrade count for IB Interface $IO_IB_IPS[$i] is $IB_Health{$IO_IB_IPS[$i]}->{DGRD}");

      &syslog_write("info","$fname: Fail count for TenGig Interface $IO_TENGIG_IPS[$i] is $TenGig_Health{$IO_TENGIG_IPS[$i]}->{FAIL}");
      &syslog_write("info","$fname: Degrade count for TenGig Interface $IO_TENGIG_IPS[$i] is $TenGig_Health{$IO_TENGIG_IPS[$i]}->{DGRD}");

      &syslog_write("info","$fname: Health of OSPF for IO node $IO_CVLAN_IPS[$i] is $STAT[$OSPF_Health[$i]]");
      &syslog_write("info","$fname: Health of IOLOG for IO node $IO_CVLAN_IPS[$i] is $STAT[$IOLOG_Health[$i]]");
      &syslog_write("info","$fname: Health status for IO node $IO_CVLAN_IPS[$i] is $STAT[$IO_Node_Health[$i]]");
    }

}

# ===================== 
# make this a daemon
# ===================== 

sub daemonize {

   POSIX::setsid or die "setsid: $!";
   my $pid = fork ();
   if ($pid < 0) {
      die "fork: $!";
   } elsif ($pid) {
      exit 0;
   }
   chdir "/";
   umask 0;
   foreach (0 .. (POSIX::sysconf (&POSIX::_SC_OPEN_MAX) || 1024))
      { POSIX::close $_ }
   open (STDIN, "</dev/null");
   open (STDOUT, ">/dev/null");
   open (STDERR, ">&STDOUT");
 }

#===============  END =============
