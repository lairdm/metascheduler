package MetaScheduler::Torque::QSub;

use strict;
use warnings;
use Log::Log4perl;
use MooseX::Singleton;
use MetaScheduler::Config;

my $logger;

sub initialize {
    my $self = shift;

    $logger = Log::Log4perl->get_logger;

}

# Submit a job to the scheduler, return
# the scheduler id (qsub_id), -1 if submission failed

sub submit_job {
    my $self = shift;
    my $name = shift;
    my $qsub_file = shift;
    my $job_dir = shift;
    
    # Clean the paths a little since qsub doesn't like //
    $job_dir =~ s/\/\//\//g;
    $qsub_file =~ s/\/\//\//g;

    my $qsub_uid = (stat $qsub_file)[4];
    my $qsub_user = (getpwuid $qsub_uid)[0];

    # Prepend MetaScheduler_ so we can find our
    # jobs later
    my $prefix = MetaScheduler::Config->config->{torque_prefix} ? MetaScheduler::Config->config->{torque_prefix} . '_' : 'MetaScheduler_';
    
    $name = $prefix . $name;

    my $cmd = MetaScheduler::Config->config->{torque_qsub}
    . " -d $job_dir -N $name ";

    # If we've been told to use proxy_user, tell qsub what user to run the
    # submission as, to work Metascheduler user must have Manager access on
    # the Torque server
    if(MetaScheduler::Config->config->{proxy_user}) {
	$cmd .= "-P $qsub_user ";
    }

    if(MetaScheduler::Config->config->{walltime}) {
	$cmd .= "-l walltime=" . MetaScheduler::Config->config->{walltime} . ' ';
    }


    $cmd .= $qsub_file;

    $logger->debug("Submitting job $cmd");

    open(CMD, '-|', $cmd);
    my $output = do { local $/; <CMD> };
    close CMD;

    my $return_code = ${^CHILD_ERROR_NATIVE};

    unless($return_code == 0) {
	# We have an error of some kind with the call
	$logger->error("Error, unable to run qsub: $cmd -d $job_dir $qsub_file, return code: $return_code, output $output");
	return -1;
    }

    # Ok, we seem to have submitted successfully... let's see if we
    # can pull a job_id out
    my $server_name = MetaScheduler::Config->config->{torque_server_name};
    unless($output =~ /(\d+)\.$server_name/) {
	# Hmm, we couldn't find a job id?
	$logger->error("Error, no job_id returned by qsub: $cmd -o $job_dir -e $job_dir $qsub_file, output $output");
	return -1;
    }

    # We've successfully submitted a job, I hope.
    my $job_id = $1;
    $logger->info("Submitted job $qsub_file, name $name, job_id $job_id");
    
    return $job_id;
}

1;
