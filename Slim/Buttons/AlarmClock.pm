# AlarmClock.pm by Kevin Deane-Freeman (kevindf@shaw.ca) March 2003
# Adapted from code by Lukas Hinsch
# Updated by Dean Blackketter
#
# This code is derived from code with the following copyright message:
#
# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

package Slim::Buttons::AlarmClock;

use strict;

use Slim::Player::Playlist;
use Slim::Buttons::Common;
use Slim::Utils::Misc;

use Scalar::Util qw(blessed);
use Time::HiRes;

my $interval    = 1;  # check every x seconds
my $FADESECONDS = 20; # fade-in of 20 seconds

my (%functions, %menuSelection, %specialPlaylists);

my @browseMenuChoices = (
	'ALARM_SET',
	'ALARM_SELECT_PLAYLIST',
	'ALARM_SET_VOLUME',
	'ALARM_OFF',
	'ALARM_WEEKDAYS',
);

# get current weekday, 0 is every day 1-7 is Monday to Sunday respectively
sub weekDay {
	my $client = shift;
	my $day = $client->param('day');

	if (defined $day) {
		return ${$day};
	} else {
		return 0;
	}
}

# some initialization code, adding modes for this module
sub init {

	Slim::Buttons::Common::addMode('alarm', getFunctions(), \&Slim::Buttons::AlarmClock::setMode);
	setTimer();

	# check if Random plugin is isntalled and not disabled.  create items for the special random playlists
	if ((grep {$_ eq 'RandomPlay::Plugin'} keys %{Slim::Buttons::Plugins::installedPlugins()}) 
		&& !(grep {$_ eq 'RandomPlay::Plugin'} Slim::Utils::Prefs::getArray('disabledplugins'))) {
			%specialPlaylists = (
				'PLUGIN_RANDOM_TRACK'	=> 'track',
				'PLUGIN_RANDOM_ALBUM'	=> 'album',
				'PLUGIN_RANDOM_ARTIST'	=> 'artist',
		);
	}
	
	# add option for the current playlist
	$specialPlaylists{'CURRENT_PLAYLIST'} = 0;

	%functions = (

		'up' => sub  {
			my $client = shift;
			my $max = ($#browseMenuChoices + 1);
			if (weekDay($client)) {
				$max--;
			}	
			my $newposition = Slim::Buttons::Common::scroll($client, -1, $max, $menuSelection{weekDay($client)}{$client});

			if ($newposition != $menuSelection{weekDay($client)}{$client}) {
				$menuSelection{weekDay($client)}{$client} = $newposition;
				$client->pushUp();
			}
		},

		'down' => sub  {
			my $client = shift;
			my $max = ($#browseMenuChoices + 1);
			if (weekDay($client)) {
				$max--;
			}	
			my $newposition = Slim::Buttons::Common::scroll($client, +1, $max, $menuSelection{weekDay($client)}{$client});

			if ($newposition != $menuSelection{weekDay($client)}{$client}) {
				$menuSelection{weekDay($client)}{$client} = $newposition;
				$client->pushDown();
			}
		},

		'left' => sub  {
			my $client = shift;

			Slim::Buttons::Common::popModeRight($client);
		},

		'right' => sub  {
			my $client   = shift;
			my @oldlines = Slim::Display::Display::curLines($client);

			my $menuChoice = $browseMenuChoices[$menuSelection{weekDay($client)}{$client}];

			# choice is alarm time set.  create params and enter the time input mode.
			if ($menuChoice eq 'ALARM_SET') {

				my %params = (
					'header'    => $client->string('ALARM_SET'),
					'valueRef'  => $client->prefGet("alarmtime", weekDay($client)),
					'cursorPos' => 0,
					'callback'  => \&exitSetHandler,
					'onChange'  => sub {
						my $client = shift;

						$client->prefSet(
							'alarmtime',
							Slim::Buttons::Common::param($client, 'valueRef'),
							weekDay($client)
						);
					},

					'onChangeArgs' => 'C',
					'day'		   => \weekDay($client),
				);

				Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Time',\%params);
			}

			# choice is playlist selection.  create params and enter the list input mode.
			if ($menuChoice eq 'ALARM_SELECT_PLAYLIST') {

				# Make a copy of the playlists, to make sure they
				# aren't removed by the LRU cache. This may fix bug: 1853
				
				my $ds   = Slim::Music::Info::getCurrentDataStore();
				
				my %params = (
					'listRef'        => [ $ds->getPlaylists(), keys %specialPlaylists],
					'externRef'      => sub { exists $specialPlaylists{$_[1]} 
									? $_[0]->string($_[1]) 
									: Slim::Music::Info::standardTitle(@_) },
					'externRefArgs'  => 'CV',
					'header'         => 'ALARM_SELECT_PLAYLIST',
					'headerAddCount' => 1,
					'stringHeader'   => 1,
					'onChange'       => sub {
						my $client = shift;
						my $item   = shift;

						$client->prefSet("alarmplaylist", $item, weekDay($client));
					},

					'onChangeArgs'   => 'CV',
					'valueRef'       => \$client->prefGet("alarmplaylist", weekDay($client)),
					'day'		     => \weekDay($client),
				);

				Slim::Buttons::Common::pushModeLeft($client, 'INPUT.List',\%params);

			# choice is alarm enable/disable.  simple toggle to activate ro deactivate the alarm.
			} elsif ($menuChoice eq 'ALARM_OFF') {
				my $newval;
				if ($client->prefGet("alarm", weekDay($client))) {
					$newval = 0;
				} else {
					$newval = 1;
				}
				
				$client->prefSet("alarm", $newval, weekDay($client));

				$client->showBriefly($client->string($newval ? 'ALARM_TURNING_ON' : 'ALARM_TURNING_OFF'),'');

				setTimer($client);

			# choice is alarm volume setting.  create params and enter the bar input mode.
			} elsif ($menuChoice eq 'ALARM_SET_VOLUME') {

				my %params = (
					'header' => sub {
							($_[0]->linesPerScreen == 1) ? 
								$_[0]->string('ALARM_SET_VOLUME_SHORT') : 
								$_[0]->string('ALARM_SET_VOLUME');
							},
					,'stringHeader' => 1,
					,'headerValue'  => \&Slim::Buttons::AlarmClock::volumeValue,
					,'onChange'     => sub {
							my $client = shift;
							my $item   = shift;

							$client->prefSet("alarmvolume", $item, weekDay($client));
					},
					'valueRef'      => \$client->prefGet("alarmvolume", weekDay($client)),
					'day'		    => \weekDay($client),
				);
				
				Slim::Buttons::Common::pushModeLeft($client, 'INPUT.Bar',\%params);

			# choice is alarm fade time setting.  create params and enter the bar input mode.
			} elsif ($menuChoice eq 'ALARM_FADE') {

				my $newval;
				if ($client->prefGet("alarmfadeseconds")) {
					$newval = 0;
				} else {
					$newval = 1;
				}
				
				$client->prefSet("alarmfadeseconds", $newval);

				$client->update();

			# choice is weekday alarms.  create params and enter the list input mode.
			# creates a list of days, so that pressing right on a day re-enters alarm menu system with the specific day set.
			} elsif ($menuChoice eq 'ALARM_WEEKDAYS') {

				# Make a copy of the playlists, to make sure they
				# aren't removed by the LRU cache. This may fix bug: 1853
				my $ds  = Slim::Music::Info::getCurrentDataStore();
				my $day = 0;
				
				my $params = {
					'listRef'        => [ 1..7 ],
					'externRef'      => sub { 
						my $client    = shift;
						my $dayOfWeek = shift;

						my $dowString = $client->string("ALARM_DAY$dayOfWeek");

						if ($client->prefGet('alarm', $dayOfWeek)) {

							$dowString .= sprintf(" (%s)",
								Slim::Buttons::Input::Time::timeString(
									$client,
									Slim::Buttons::Input::Time::timeDigits(
										$client,
										$client->prefGet('alarmtime', $day)
									),
									-1  # hide the cursor
								) 
							);
						
						} else {
							$dowString .= sprintf(" (%s)", $client->string('MCOFF'));
						}

						return $dowString;
					},

					'externRefArgs'  => 'CV',
					'header'         => 'ALARM_WEEKDAYS',
					'headerAddCount' => 1,
					'stringHeader'   => 1,
					'valueRef'       => \$day,
					'callback'       => \&weekdayExitHandler,
					'day'		     => \weekDay($client),
				};

				Slim::Buttons::Common::pushModeLeft($client, 'INPUT.List', $params);
			} 
		},

		'play' => sub {
			my $client = shift;
		},
	);
}

# the routines
sub setMode {
	my $client = shift;

	my $weekDay = weekDay($client);
	
	# get a default menu position if none already exists. This will remember previous positions by client.
	unless (defined $menuSelection{$weekDay}{$client}) {
		$menuSelection{$weekDay}{$client} = 0;
	}

	# set the lines function for this mode.
	$client->lines(\&lines);

	# get previous alarm time or set a default
	my $time = $client->prefGet("alarmtime", $weekDay);

	# create a preset time if none is found.
	unless (defined $time) {
		$client->prefSet("alarmtime", 9 * 60 * 60, $weekDay);
	}
	
	# entering alarm settings, add teh fade timing global pref unless already there
	if (!defined $client->param('day')) {
		push @browseMenuChoices, 'ALARM_FADE' unless $browseMenuChoices[-1] eq 'ALARM_FADE';
	
	# remove for weekday pref menus
	} elsif($browseMenuChoices[-1] eq 'ALARM_FADE') {
		pop @browseMenuChoices;
	}
}

# on exiting the weekday list, this handler will deal the exit left to the previous 
# menu, or right into that days setting options list.
sub weekdayExitHandler {
	my ($client, $exittype) = @_;

	$exittype = uc($exittype);

	if ($exittype eq 'LEFT') {

		Slim::Buttons::Common::popModeRight($client);

	} elsif ($exittype eq 'RIGHT') {

		my %params = (
			'day' => $client->param('valueRef'),
		);

		Slim::Buttons::Common::pushModeLeft($client,'alarm', \%params);
	}
}

# handler for exiting teh time setting input mode.  stores the time as a pref.
sub exitSetHandler {
	my ($client, $exittype) = @_;

	$exittype = uc($exittype);

	if ($exittype eq 'LEFT' || $exittype eq 'PLAY') {

		$client->prefSet("alarmtime", $client->param('valueRef'), weekDay($client));

		Slim::Buttons::Common::popModeRight($client);

	} elsif ($exittype eq 'RIGHT') {

		$client->bumpRight();
	}
}

sub setTimer {
	# timer to check alarms on an interval
	Slim::Utils::Timers::setTimer(0, Time::HiRes::time() + $interval, \&checkAlarms);
}

sub checkAlarms {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday) = localtime(time);

	my $time = $hour * 60 * 60 + $min * 60;
	
	# bug 2300: prefs refers to sunday as day 7, so correct this here for localtime
	$wday = 7 if !$wday;
	
	# once we've reached the beginning of a minute, only check every 60s
	if ($sec == 0) {
		$interval = 60;
	}

	# if we end up falling behind, go back to checking each second
	if ($sec >= 50) {
		$interval = 1;
	}

	foreach my $client (Slim::Player::Client::clients()) {

		for my $day (0, $wday) {

			# don't bother for inactive alarms.
			next unless $client->prefGet("alarm", $day);

			my $alarmtime = $client->prefGet("alarmtime", $day) || next;

			if ($time == ($alarmtime + 60)) {

				# alarm is done, so reset to find the beginning of a minute
				$interval = 1;
			}

			if ($time == $alarmtime) {

				$client->execute(['stop']);

				my $volume = $client->prefGet("alarmvolume", $day);

				if (defined ($volume)) {
					$client->execute(["mixer", "volume", $volume]);
				}

				# fade volume over 20s if enabled.
				$client->fade_volume($client->prefGet("alarmfadeseconds") * $FADESECONDS);

				my $playlist = $client->prefGet("alarmplaylist", $day);
				
				# if a random playlist option is chosen, make sure that the plugin is installed and enabled.
				if ($specialPlaylists{$playlist} && ((grep {$_ eq 'RandomPlay::Plugin'} keys %{Slim::Buttons::Plugins::installedPlugins()}) 
							&& !(grep {$_ eq 'RandomPlay::Plugin'} Slim::Utils::Prefs::getArray('disabledplugins')))) {
					
					Plugins::RandomPlay::Plugin::playRandom($client,$specialPlaylists{$playlist});
					
				# handle a chosen playlist that is not the current playlist.
				} elsif (defined $playlist && $playlist ne 'CURRENT_PLAYLIST') {

					$client->execute(["power", 1]);

					Slim::Buttons::Block::block($client, alarmLines($client));
					
					my $ds = Slim::Music::Info::getCurrentDataStore();
					my $playlistObj = $ds->objectForUrl($playlist);

					if (blessed($playlistObj) && $playlistObj->can('id')) {

						$client->execute(["playlist", "playtracks", "playlist=".$playlistObj->id], \&playDone, [$client]);
						setTimer();
						return;
					
					#if all else fails, just try to play the current playlist.
					} else {
						# no object, so try to play the current playlist
						$client->execute(['play']);
					}

				# check random playlist choice, but only if RandomPlay plugin is enabled at this time.

				#fallback to current playlist if all else fails.
				} else {

					$client->execute(['play']);

				}
				
				# slight delay for things to load up before showing the temporary alarm lines.
				Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&visibleAlarm, $client);
			}
		}
	}

	setTimer();
}

# on a playlist load, call this after the playlist loading is complete to set the timer for the visible alert 2 seconds in the future.
sub playDone {
	my $client = shift;

	Slim::Buttons::Block::unblock($client);

	# show the alarm screen after a couple of seconds when the song has started playing and the display is updated
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&visibleAlarm, $client);	
}

# temporary lines shown after alarm triggers, just to let the user know why the music started.
sub alarmLines {
	my $client = shift;

	my $line1 = $client->string('ALARM_NOW_PLAYING');
	my $line2 = '';

	my $playlist = $client->prefGet("alarmplaylist", weekDay($client));
	
	# special playlists, just show the localised string for the option
	if (exists $specialPlaylists{$playlist}) {
		$line2 = $client->string($playlist);
		
	} else {

		# show the standard title for the loaded playlist item
		$line2 = Slim::Music::Info::standardTitle($client, $playlist);
	}

	return ($line1, $line2);
}

sub visibleAlarm {
	my $client = shift;

	# show visible alert for 30s
	$client->showBriefly(alarmLines($client), 30);
}

sub lines {
	my $client = shift;
	my $weekDay = weekDay($client);
	my $index = $menuSelection{$weekDay}{$client};
	my $line1;
	my $line2;
	my $max;
	
	my $overlay2 =  $client->symbols('rightarrow');
	
	# create line 1, showing the chosen weekday if applicable
	if ($weekDay) {
		$line1 = sprintf('%s - %s', $client->string('ALARM_WEEKDAYS'), $client->string("ALARM_DAY$weekDay"));
		$max = scalar(@browseMenuChoices) - 1;
	} else {
	 	$line1 = $client->string('ALARM');
	 	$max = scalar(@browseMenuChoices);
	}
	
	$line1 .= ' (' . ($index + 1) . ' ' . $client->string('OF') .' ' . $max . ')';
	
	# show alarm state when the right menu item is selected.  otherwise, 
	# just show the string for the other menu items as selected.
	if ($client->prefGet("alarm", $weekDay) && $browseMenuChoices[$index] eq 'ALARM_OFF') {
		$line2 = $client->string('ALARM_ON');
	} else {
		$line2 = $client->string($browseMenuChoices[$index]);
	}
	
	if ($browseMenuChoices[$index] eq 'ALARM_FADE') {
		$overlay2 = Slim::Buttons::Common::checkBoxOverlay($client->prefGet("alarmfadeseconds"));
	}

	return {
		'line1'   => $line1,
		'line2'   => $line2,
		'overlay2' => $overlay2,
	};
}

sub getFunctions {
	return \%functions;
}

sub getSpecialPlaylists {
	return \%specialPlaylists;
}

sub volumeValue {
	my ($client,$arg) = @_;
	return ' ('.($arg <= 0 ? $client->string('MUTED') : int($arg/100*40+0.5)).')';
}

1;

__END__
