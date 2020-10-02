#!/usr/bin/env perl

=head SYNOPSIS

Based off example of L<A media player in GTK+|https://gstreamer.freedesktop.org/documentation/tutorials/basic/toolkit-integration.html#a-media-player-in-gtk>

=cut

use strict;
use warnings;

package # hide from CPAN
	GSTIntegration;

use Renard::Incunabula::Common::Setup;
use Renard::Incunabula::Common::Types qw(InstanceOf Str Int Maybe);
use Type::Tie;
use Mu;

use Glib qw(TRUE FALSE);
use Intertangle::API::Gtk3::Helper;
use Intertangle::API::Gtk3::WindowID;
use Intertangle::API::GStreamer;
use Intertangle::API::GStreamer::Integration::Gtk3;

rw uri => (
	required => 0,
	default => fun() {
		@ARGV
		? $ARGV[0]
		: "https://www.freedesktop.org/software/gstreamer-sdk/data/media/sintel_trailer-480p.webm";
	},
	isa => Str,
);

rw playbin => (
	required => 0,
	isa => InstanceOf['GStreamer1::Element'],
	doc => "Our one and only pipeline",
);

rw slider => (
	required => 0,
	isa => InstanceOf['Gtk3::Scale'],
	doc => "Slider widget to keep track of current position",
);
rw streams_list => (
	required => 0,
	isa => InstanceOf['Gtk3::TextView'],
	doc => "Text widget to display info about the streams",
);
rw slider_update_signal_id => (
	required => 0,
	isa => Int,
	doc => "Signal ID for the slider update signal",
);

rw state => (
	required => 0,
	#isa => InstanceOf['GStreamer1::State'],
	doc => "Current state of the pipeline",
);

rw duration => (
	required => 0,
	isa => Int,
	doc => "Duration of the clip, in nanoseconds",
);

fun main() {
	my $ret;# InstanceOf['GStreamer1::StateChangeReturn']
	ttie my $bus, Maybe[InstanceOf['GStreamer1::Bus']];

	GStreamer1::init([$0, @ARGV]);

	my $self = __PACKAGE__->new;
	$self->duration( GStreamer1::CLOCK_TIME_NONE );

	# Create the elements
	$self->playbin( GStreamer1::ElementFactory::make("playbin", "playbin") );

	unless($self->playbin) {
		die "Not all elements could be created.";
	}


	# Set the URI to play
	$self->playbin->set( 'uri', $self->uri );

	# Connect to interesting signals in playbin
	$self->playbin->signal_connect( $_, \&tags_cb, $self )
		for qw(video-tags-changed audio-tags-changed text-tags-changed);

	# Create the GUI
	$self->create_ui;

	# Instruct the bus to emit signals for each received message, and connect to the interesting signals
	$bus = GStreamer1::Element::get_bus ($self->playbin);
	$bus->add_signal_watch;
	$bus->signal_connect("message::error", \&error_cb, $self);
	$bus->signal_connect("message::eos", \&eos_cb, $self);
	$bus->signal_connect("message::state-changed", \&state_changed_cb, $self);
	$bus->signal_connect("message::application", \&application_cb, $self);

	undef $bus;

	# Start playing
	$ret = $self->playbin->set_state('playing');
	if ($ret eq 'state-change-failure' ) {
		die "Unable to set the pipeline to the playing state.";
	}

	# Register a function that GLib will call every second
	Glib::Timeout->add_seconds(1, \&refresh_ui, $self );

	# Start the GTK main loop. We will not regain control until gtk_main_quit is called.
	Gtk3::main;

	# Free resources
	$self->playbin->set_state( 'null' );

	return 0;
}

main;


=callback realize_cb

This function is called when the GUI toolkit creates the physical window that
will hold the video.  At this point we can retrieve its handler (which has a
different meaning depending on the windowing system) and pass it to GStreamer
through the VideoOverlay interface.

=cut
callback realize_cb ( (InstanceOf['Gtk3::Widget']) $widget, $self) {
	Intertangle::API::GStreamer::Integration::Gtk3->set_window_handle(
		$self->playbin,
		$widget
	);
}

=callback play_cb

This function is called when the PLAY button is clicked

=cut
callback play_cb ( (InstanceOf['Gtk3::Button']) $button, $self) {
	$self->playbin->set_state( 'playing' );
}

=callback pause_cb

This function is called when the PAUSE button is clicked

=cut
callback pause_cb ( (InstanceOf['Gtk3::Button']) $button, $self) {
	$self->playbin->set_state( 'paused' );
}

=callback stop_cb

This function is called when the STOP button is clicked

=cut
callback stop_cb ( (Maybe[ InstanceOf['Gtk3::Button'] ]) $button, $self) {
	$self->slider->set_value(0);
	$self->playbin->set_state( 'ready' );
}

=callback delete_event_cb

This function is called when the main window is closed

=cut
callback delete_event_cb ( (InstanceOf['Gtk3::Widget']) $widget, (InstanceOf['Gtk3::Gdk::Event']) $event, $self) {
	stop_cb(undef, $self);
	Gtk3::main_quit;
}

=callback draw_cb

This function is called everytime the video window needs to be redrawn (due to
damage/exposure, rescaling, etc). GStreamer takes care of this in the PAUSED
and PLAYING states, otherwise, we simply draw a black rectangle to avoid
garbage showing up.

=cut
callback draw_cb ( (InstanceOf['Gtk3::Widget']) $widget, (InstanceOf['Cairo::Context']) $cr, $self) {
	if ( !defined $self->state || $self->state lt 'paused') {
		my $allocation; #GtkAllocation allocation;

		# Cairo is a 2D graphics library which we use here to clean the
		# video window.  It is used by GStreamer for other reasons, so
		# it will always be available to us.
		$allocation = $widget->get_allocation;
		$cr->set_source_rgb(0, 0, 0);
		$cr->rectangle(0, 0, $allocation->{width}, $allocation->{height});
		$cr->fill;
	}

	return FALSE;
}

=callback slider_cb

This function is called when the slider changes its position. We perform a seek
to the new position here.

=cut
callback slider_cb ( (InstanceOf['Gtk3::Range']) $range, $self) {
	my $value = $self->slider->get_value; # gdouble
	$self->playbin->seek_simple(
		'time',
		[ 'flush' , 'key-unit' ],
		$value * GStreamer1::SECOND
	)
}

=method create_ui

This creates all the GTK+ widgets that compose our application, and registers the callbacks

=cut
method create_ui () {
	my $main_window;  # The uppermost window, containing all other windows
	my $video_window; # The drawing area where the video will be shown
	my $main_box;     # VBox to hold main_hbox and the controls
	my $main_hbox;    # HBox to hold the video_window and the stream info text widget
	my $controls;     # HBox to hold the buttons and the slider
	my ($play_button, $pause_button, $stop_button); # Buttons

	$main_window = Gtk3::Window->new('toplevel');
	$main_window->signal_connect( "delete-event" => \&delete_event_cb, $self );

	$video_window = Gtk3::DrawingArea->new;
	$video_window->set_double_buffered(FALSE);
	$video_window->signal_connect( realize => \&realize_cb, $self );
	$video_window->signal_connect( draw => \&draw_cb, $self );

	my $small_toolbar = Intertangle::API::Gtk3::Helper->genum( 'Gtk3::IconSize', 'small-toolbar' );
	$play_button = Gtk3::Button->new_from_icon_name ("media-playback-start", $small_toolbar);
	$play_button->signal_connect( clicked => \&play_cb, $self );

	$pause_button = Gtk3::Button->new_from_icon_name("media-playback-pause", $small_toolbar);
	$pause_button->signal_connect( clicked => \&pause_cb, $self );

	$stop_button = Gtk3::Button->new_from_icon_name("media-playback-stop", $small_toolbar);
	$stop_button->signal_connect( clicked => \&stop_cb, $self );

	$self->slider( Gtk3::Scale->new_with_range('horizontal', 0, 100, 1) );
	$self->slider->set_draw_value(0);
	$self->slider_update_signal_id(
		$self->slider->signal_connect( "value-changed", \&slider_cb, $self )
	);

	$self->streams_list( Gtk3::TextView->new );
	$self->streams_list->set_editable( FALSE );

	$controls = Gtk3::Box->new ('horizontal', 0);
	$controls->pack_start( $play_button, FALSE, FALSE, 2);
	$controls->pack_start( $pause_button, FALSE, FALSE, 2);
	$controls->pack_start( $stop_button, FALSE, FALSE, 2);
	$controls->pack_start( $self->slider, TRUE, TRUE, 2);

	$main_hbox = Gtk3::Box->new ('horizontal', 0);
	$main_hbox->pack_start( $video_window, TRUE, TRUE, 0);
	$main_hbox->pack_start( $self->streams_list, FALSE, FALSE, 2);

	$main_box = Gtk3::Box->new ('vertical', 0);
	$main_box->pack_start( $main_hbox, TRUE, TRUE, 0);
	$main_box->pack_start( $controls, FALSE, FALSE, 0);

	$main_window->add($main_box);
	$main_window->set_default_size( 640, 480);

	$main_window->show_all;
}

=method refresh_ui

This function is called periodically to refresh the GUI

=cut
method refresh_ui () {
	my $current = -1; # gint64

	# We do not want to update anything unless we are in the PAUSED or PLAYING states
	return TRUE if !defined $self->state || $self->state lt 'paused';


	# If we didn't know it yet, query the stream duration
	if ( $self->duration == GStreamer1::CLOCK_TIME_NONE ) {
		my ($query, $duration) = $self->playbin->query_duration( 'time'  );
		if (!$query) {
			say STDERR "Could not query current duration.";
		} else {
			$self->duration( $duration );
			# Set the range of the slider to the clip duration, in SECONDS
			$self->slider->set_range(0, $self->duration / GStreamer1::SECOND );
		}
	}

	my $query;
	($query, $current) = $self->playbin->query_position( 'time' );
	if ($query) {
		# Block the "value-changed" signal, so the slider_cb function
		# is not called (which would trigger a seek the user has not
		# requested)
		Glib::Object::signal_handler_block( $self->slider, $self->slider_update_signal_id );
		# Set the position of the slider to the current pipeline
		# position, in SECONDS
		$self->slider->set_value( $current / GStreamer1::SECOND );
		# Re-enable the signal
		Glib::Object::signal_handler_unblock( $self->slider, $self->slider_update_signal_id );
    }

	return TRUE;
}

=callback tags_cb

This function is called when new metadata is discovered in the stream

=cut
callback tags_cb ( (InstanceOf['GStreamer1::Element']) $playbin, (Int) $stream, $self) {
	# We are possibly in a GStreamer working thread, so we notify the main
	# thread of this event through a message in the bus
	$playbin->post_message(
		GStreamer1::Message->new_application( $playbin,
			GStreamer1::Structure->new_empty("tags-changed")
		)
	);
}

=callback error_cb

This function is called when an error message is posted on the bus

=cut
callback error_cb ( (InstanceOf['GStreamer1::Bus']) $bus, (InstanceOf['GStreamer1::Message']) $msg, $self) {
	my $err; # GError
	my $debug_info; # gchar*

	# Print error details on the screen

	# The following gives an exception:
	#   FIXME - GI_TYPE_TAG_ERROR
	# See <https://mail.gnome.org/archives/gtk-perl-list//2015-July/msg00011.html>.
	#($err, $debug_info) = $msg->parse_error;

	my $struct = $msg->get_structure;
	($err, $debug_info) = ( $struct->get_value('gerror') , $struct->get_string('debug') );
	say STDERR sprintf "Error received from element %s: %s", $msg->src->get_name, $err->message;
	say STDERR sprintf "Debugging information: %s", $debug_info ? $debug_info : "none";

	# Set the pipeline to READY (which stops playback)
	$self->playbin->set_state('ready');
}

=callback eos_cb

This function is called when an End-Of-Stream message is posted on the bus.
We just set the pipeline to READY (which stops playback)

=cut
callback eos_cb ( (InstanceOf['GStreamer1::Bus']) $bus, (InstanceOf['GStreamer1::Message']) $msg, $self) {
	say "End-Of-Stream reached.\n";
	$self->playbin->set_state('ready');
}

=callback state_changed_cb

This function is called when the pipeline changes states. We use it to keep
track of the current state.

=cut
callback state_changed_cb ( (InstanceOf['GStreamer1::Bus']) $bus, (InstanceOf['GStreamer1::Message']) $msg, $self) {
	my ($old_state, $new_state, $pending_state); # GstState
	($old_state, $new_state, $pending_state) = $msg->parse_state_changed;

	if ($msg->src == $self->playbin) {
		$self->state( $new_state );
		say sprintf("State set to %s", $new_state);

		if( $old_state eq 'ready' && $new_state eq 'paused' ) {
			# For extra responsiveness, we refresh the GUI as soon
			# as we reach the PAUSED state
			$self->refresh_ui;
		}
	}
}

=method analyze_streams

Extract metadata from all the streams and write it to the text widget in the GUI

=cut
method analyze_streams () {
	my $tags; # GstTagList
	my ($str, $total_str); # gchar
	my $rate; # guint
	my ($n_video, $n_audio, $n_text); # gint
	my $text; # GtkTextBuffer

	# Clean current contents of the widget
	$text = $self->streams_list->get_buffer;
	$text->set_text("", -1);

	# Read some properties
	$n_video = $self->playbin->get('n-video');
	$n_audio = $self->playbin->get('n-audio');
	$n_text = $self->playbin->get('n-text');

	for my $i (0..$n_video-1) {
		undef $tags;
		# Retrieve the stream's video tags
		$tags = $self->playbin->signal_emit("get-video-tags", $i);
		if( $tags ) {
			$total_str .= "video stream $i:\n";
			$total_str .= "  codec: @{[ $tags->get_string('video-codec') || 'unknown' ]}\n";
		}
	}
	for my $i (0..$n_audio-1) {
		undef $tags;
		# Retrieve the stream's audio tags
		$tags = $self->playbin->signal_emit("get-audio-tags", $i);
		if( $tags ) {
			$total_str .= "\naudio stream $i:\n";
			my %info = (
				'audio-codec' => 'codec',
				'language-code' => 'language',
				'bitrate' => 'bitrate',
			);
			for my $string ( qw(audio-codec language-code bitrate) ) {
				if( my $data = $tags->get_string($string) ) {
					$total_str .= "  @{[ $info{$string} ]}: $data\n";
				}
			}
		}
	}
	for my $i (0..$n_text-1) {
		undef $tags;
		# Retrieve the stream's subtitle tags
		$tags = $self->playbin->signal_emit("get-text-tags", $i);
		if( $tags ) {
			$total_str .= "\nsubtitle stream $i:\n";
			my %info = (
				'language-code' => 'language',
			);
			for my $string ( qw(language-code) ) {
				if( my $data = $tags->get_string($string) ) {
					$total_str .= "  @{[ $info{$string} ]}: $data\n";
				}
			}
		}
	}

	$text->set_text($total_str, -1);
}

=callback application_cb

This function is called when an "application" message is posted on the bus.
Here we retrieve the message posted by the tags_cb callback

=cut
callback application_cb ( (InstanceOf['GStreamer1::Bus']) $bus, (InstanceOf['GStreamer1::Message']) $msg, $self) {
	if( $msg->get_structure->get_name eq "tags-changed" ) {
		#/* If the message is the "tags-changed" (only one we are currently issuing), update
		# * the stream info GUI */
		$self->analyze_streams;
	}
}

