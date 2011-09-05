#!/usr/bin/env ruby

require 'eventmachine'
require 'logger'
require 'thread'
require 'singleton'

Thread.abort_on_exception = true

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

		$logger.debug("Got a new file to monitor (#{filename})")

		EM.next_tick {
			$seen[filename] = EM.watch_file(filename, FileHandler)
		}

	}

	# Handle files no longer being written to

	old = $seen.keys() - active

	old.each { |filename| 
		$logger.debug("ttyrec stopped on (#{filename})")
		# XXX $seen[filename].stop_watching()
		$seen.delete(filename)
	}

end

module FileHandler
	# offset = ?
	def process_frames
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

			@offset += 12 + len

			# well, I lied.
			@MM.add_frames(path, [ ts, data ])
		end

		fp.close()


	end

	def initialize
		@offset = 0
		@lock = Mutex.new
		@MM = MovieMaker.instance
	end

	def file_modified
		$logger.debug("#{path} modified")
		Thread.new { 
			# Not entirely race proof
			return if @lock.locked?

			@lock.synchronize {
				process_frames() 
			}
		}
	end

	def unbind
		@MM.delete_movie(path)
	end
end

SECONDS = 5

# MovieMaker produces an 30 second clip from upto 6 different sessions
# of upto 30 seconds length compressed down to all fit in 30 seconds
class MovieMaker
	include Singleton

	def delete_movie(filename)
		@partial.delete(filename)
	end

	def add_frames(filename, frames)
		$logger.debug("adding frames to MovieMaker")
		@partial[filename] << frames
	end

	def make_movies()
		while (true)
			@partial.each { |k, v| 
				start = v[0][0]
				stop = v[-1][0]

				$logger.debug("#{filename} #{stop} - #{start} = #{stop - start}")

				next if ((stop - start) < SECONDS)

				$logger.debug("Producing 30 sec clip")

				# bail if none found
				# delete upto / 30 second, leave rest
			}

			select(nil, nil, nil, 5)
		end
	end

	def initialize
		@partial = Hash.new { |h, k| h[k] = [] }
		@clips = []
		Thread.new { make_movies() }
	end

end

# MoviePlayer fetches movies and streams them to the client. 
class MoviePlayer < EventMachine::Connection
	def post_init
		@MM = MovieMaker.instance()
		# consume output from mm
		# XXX, reset the terminal
		# indicate that we want to consume from moviemaker
	end

	def receive_data(data)
		# should not be sent data, so hang up ?
	end
end

EventMachine::run do
	EventMachine::add_periodic_timer(2) do
		# XXX, run in thread :)
		scan_processes()
	end

	EventMachine::start_server("0.0.0.0", 10000, MoviePlayer)
end		
