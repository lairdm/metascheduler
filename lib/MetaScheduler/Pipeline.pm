=head1 NAME

    MetaScheduler::Pipeline

=head1 DESCRIPTION

    Object for holding and managing individual pipelines

=head1 AUTHOR

    Matthew Laird
    Brinkman Laboratory
    Simon Fraser University
    Email: lairdm@sfu.ca

=head1 LAST MAINTAINED

    March 27, 2013

=cut

package MetaScheduler::Pipeline;

use strict;
use warnings;
use JSON;
use Data::Dumper;
use Log::Log4perl;
use Graph::Directed;
use Moose;

my $pipeline;
my $logger;
my $g;
my $job;

sub BUILD {
    my $self = shift;
    my $args = shift;

    $logger = Log::Log4perl->get_logger;

    die "Error, no pipeline file given" unless($args->{pipeline});

    $self->read_pipeline($args->{pipeline});

    $self->build_tree;
}

sub read_pipeline {
    my ($self, $pipeline_file) = @_;

    $logger->debug("Reading pipeline file $pipeline_file\n");

    die "Error, pipeline file not readable: $pipeline_file"
	unless ( -f $pipeline_file && -r $pipeline_file );

    my $json;
    {
	local $/; #enable slurp
	open my $fh, "<", "$pipeline_file";
	$json = <$fh>;
    } 

    eval {
	$pipeline = decode_json($json);
    };
    if($@) {
	# Error decoding JSON
	die "Error, can not decode pipeline file $pipeline_file: $!";
    }

}

sub build_tree {
    my ($self) = @_;

    $logger->debug("Building the graph for the pipeline");
    $g = Graph::Directed->new;

    foreach my $component (@{$pipeline->{'components'}}) {
	my $name = $component->{name};
	$logger->debug("Adding component $name");
	$self->add_edges($name, $component->{on_success}, 'success')
	    if($component->{on_success});

	$self->add_edges($name, $component->{on_failure}, 'failure')
	    if($component->{on_failure});

    }
    
    unless($g->is_dag()) {
	$logger->error("Error, pipeline for $pipeline->{job_type} isn't a directed acyclic graph");
	die "Error, pipeline for $pipeline->{job_type} isn't a directed acyclic graph";
    }

    if($g->isolated_vertices()) {
	$logger->error("Error, pipeline for $pipeline->{job_type} has unreachable components");
	die "Error, pipeline for $pipeline->{job_type} has unreachable component";
    }

    print "Graph:\n$g\n";

}

sub add_edges {
    my ($self, $origin, $vertices, $label) = @_;

    $logger->debug("Adding edges for component $origin, label $label, verticies $vertices");

    foreach my $d (split ',', $vertices) {
	$g->add_edge($origin, $d);
	$g->set_edge_attribute($origin, $d, $label, 1);
    }
}

sub find_entry_points {
    my $self = shift;

    my @v = $g->source_vertices();

    print Dumper @v;
    return @v;
}

sub attach_job {
    my $self = shift;
    $job = shift;

    $self->overlay_job;
}

# We call this each time the scheduler wants to give the
# job a turn to run a step

sub run_iteration {
    
}

sub overlay_job {
    my $self = shift;

    unless(($job->run_status eq "RUNNING") ||
	   ($job->run_status eq "ERROR") ||
	   ($job->run_status eq "COMPLETE")) {

	$logger->info("Job is in state " . $job->run_state . ", not overlaying over pipeline");
	return;
    }

    my @starts = $self->find_entry_points;

    # Walk the graph and remove edges for completed/errored jobs
    foreach my $start (@starts) {
	my $v = $start;

	$self->overlay_walk_component($v);
    }
    
}

sub overlay_walk_component {
    my $self = shift;
    my $v = shift;

    $logger->debug("Walking component $v");

    if($g->is_sink_vertex($v)) {
	$logger->debug("Vertex $v is a sink, stopping");
	return;
    } else {
	my $state = $job->find_component_state($v);

	if($state eq "COMPLETE") {
	    # Job is complete, we remove the on_failure edges
	    # and continue walking the on_success edges
	    $self->remove_edges($v, "failure");
	} elsif($state eq "ERROR") {
	    # Job failed, we remove the on_success edges
	    # and continue to walk the on_failure edges
	    $self->remove_edges($v, "success");
	} elsif($state eq "PENDING") {
	    # Hasn't started yet, we stop here because we
	    # don't know which direction to go
	    $logger->debug("Component $v is PENDING, no where to go");
	    return;

	} elsif($state eq "HOLD") {
	    # Component is on hold, we stop here because we
	    # don't know which direction to go
	    $logger->debug("Component $v is HOLD, no where to go");
	    return;

	} elsif($state eq "RUNNING") {
	    # Component is running, we stop here because we
	    # don't know which direction to go
	    $logger->debug("Component $v is RUNNING, no where to go");
	    return;

	} else {
	    $logger->error("Unknown state for component $v");
	    die "Error, unknown state for component $v";
	}

	# Recursively walk the remaining edges, if any
	foreach my $u ($g->successors($v)) {
	    $self->overlay_walk_component($u);
	}
    }
}

sub remove_edges {
    my $self = shift;
    my $v = shift;
    my $attr = shift;

    foreach my $u ($g->successors($v)) {

	if($g->has_edge_attribute($v, $u, $attr)) {
	    $logger->debug("Removing attribute from edge $v, $u: $attr");
	    $g->delete_edge_attribute($v, $u, $attr);
	    unless($g->has_edge_attributes($v, $u)) {
		$logger->debug("Removing edge $v, $u with value $attr");
		$g->delete_edge($v, $u);
		$self->scrub_dangling_vertices($u);
	    } else {
		$logger->debug("Multiple attributes on edge $v, $u, not deleting");
	    }
	}
    }
}

# When we walk the graph and remove an edge
# we have to clean up in case it leaves a 
# dangling start point (a vertex with no parents),
# this would get caught in our next scan for start points

sub scrub_dangling_vertices {
    my $self = shift;
    my $v = shift;

    return unless($g->is_predecessorless_vertex($v));

    my @successors = $g->successors($v);

    $logger->debug("Vertex $v has no parents, removing");
    $g->delete_vertex($v);

    foreach my $u (@successors) {
	$self->scrub_dangling_vertices($u);
    }
}

sub fetch_component {
    my ($self, $name) = @_;

    die "Error, no pipeline loaded"
	unless($pipeline);

    $logger->debug("Returning pipeline component $name");

    foreach my $component (@{$pipeline->{'components'}}) {
	return $component
	    if($name eq $component->{'name'});
    }

    return 0;
}

sub dump_graph {
    print "Graph $g\n";
}

1;
