#!/usr/bin/env ruby

require 'eventmachine'

$seen = {}

# Loop over the processes and find active ttyrec processes. Extracts
# the filename from the process and monitors it. Stops monitoring files
# if the ttyrec process is no longer running.

def scan_processes()
	active = []

	Dir['/proc/*/cmdline'].each { |file|
		argv = open(file, "r").read().split("\x00")
		next unless argv[0] == "ttyrec" 

		# XXX, extra sanity checking required.

		filename = argv[1]
		next unless $seen[filename].nil?

		$seen[filename] = true

		puts "argv is #{argv.join(' ')}"
		active << filename
	}

	# Handle files no longer being written to

	old = $seen.keys() - active

	old.each { |filename| 
		puts "#{filename} is no longer being written"
		$seen.delete(filename)
	}
end

EventMachine::run do
	EventMachine::add_periodic_timer(1) do
		# XXX, run in thread :)
		scan_processes()
	end
end		
