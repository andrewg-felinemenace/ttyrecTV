#!/usr/bin/env ruby

require 'eventmachine'
require 'logger'

$seen = {}
$logger = Logger.new('crap.log')
$logger.level = Logger::DEBUG

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
		active << filename unless active.include?(filename)

		next unless $seen[filename].nil?

		$logger.debug('Got a new file to monitor (#{filename})')

		EM.next_tick {
			$seen[filename] = EM.watch_file(filename, FileHandler)
		}

	}

	# Handle files no longer being written to

	old = $seen.keys() - active

	old.each { |filename| 
		$logger.debug('ttyrec stopped on (#{filename})')
		# XXX $seen[filename].stop_watching()
		$seen.delete(filename)
	}

end

module FileHandler
	# offset = ?
	def process_frames
		frames = []

		fp = open(path, "r")
		fp.seek(@offset)

		while(true) do
			header = fp.read(12)
			return if header.nil?

			t1, t2, len = header.unpack("VVV")
		
			ts = t1 + (t2 / 1000000)
			$logger.debug("length is #{len}, timestamp is #{ts}")
		
			data = fp.read(len)
			return if data.nil?

			print data

			frames << [ ts, data ]
			@offset += 12 + len
		end

		fp.close()
	end

	def initialize
		@offset = 0
	end

	def file_modified
		$logger.debug("#{path} modified")
		process_frames()
	end
end

EventMachine::run do
	EventMachine::add_periodic_timer(2) do
		# XXX, run in thread :)
		scan_processes()
	end
end		
