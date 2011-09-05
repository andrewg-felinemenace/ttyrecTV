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
		argv = open(file, "r").read().split("\x00") rescue next
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
		EM.next_tick {
			$logger.debug("ttyrec stopped on (#{filename})")
			$seen[filename].stop_watching()
			$seen.delete(filename)
		}
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
		
			ts = Float(t1) + (Float(t2) / 1000000)
			@basets ||= ts 
			adj_ts = ts - @basets

			$logger.debug("length is #{len}, adjusted timestamp is #{adj_ts}")
		

			data = fp.read(len)
			return if data.nil?

			#print data

			@offset += 12 + len

			@TS.queue.push([ adj_ts, data ])

		end

		fp.close()


	end

	def initialize
		@offset = 0
		@lock = Mutex.new
		@TS = TimeFilter.new(path)
	end

	def file_modified
		$logger.debug("#{path} modified")
		Thread.new { 
			# Not entirely race proof
			if(@lock.try_lock()) then
				process_frames() 
			end
		}
	end

	def unbind
		@TS.queue << nil # indicate EOF
	end
end

SECONDS = 30

class TimeFilter
	attr_accessor :queue
	def initialize(name)
		@queue = Queue.new()
		@MM = MovieMaker.instance
		@name = name

		Thread.new { filter_queue }
	end

	def filter_queue()
		clips = [] 

		while(true) 
			timestamp, data = @queue.pop()
			break if timestamp.nil?

			# Keep a record of the first timestamp
			prev_ts ||= timestamp

			# Convert to relative time stamp for delaying
			adj_ts = timestamp - prev_ts

			# Keep SECONDS window of frames
			past ||= (timestamp / SECONDS).floor
			cur = (timestamp / SECONDS).floor

			if(cur > past) then
				send_to_movie_maker(clips)

				clips = []
				past = cur
			end

			clips << [ adj_ts, data ] 

			prev_ts = timestamp
		end

		send_to_movie_maker(clips) if clips.length > 0

		$logger.debug("TimeFilter -- got EOF")
	end

	def send_to_movie_maker(clip)
		# queue on MovieMaker
		$logger.debug("Queuing clip into MovieMaker")
		@MM.clips << clip
	end

end

# MovieMaker produces an 30 second clip from upto 6 different sessions
# of upto 30 seconds length compressed down to all fit in 30 seconds
class MovieMaker
	include Singleton
	attr_accessor :clips

	def initialize
		@clips = Queue.new()
	end

end

# MoviePlayer fetches movies and streams them to the client. 
class MoviePlayer < EventMachine::Connection
	def play_movie
		while(true) do
			# producer/consumer might be better, @MM pushes us
			# a clip to display, etc. can schedule a write later

			$logger.debug("Waiting for new movie clip")
			clip = @MM.clips.pop()
			$logger.debug("got new movie clip, resetting client")

			send_data("\x1b\x5b2J") # reset screen
			send_data("\x1b\x5bH") # move to home

			clip.each { |delay, data|
				$logger.debug("delay of #{delay}, data.length = #{data.length}")
				send_data(data)
				select(nil, nil, nil, delay * 0.50)
			}
		end

	end

	def post_init
		@MM = MovieMaker.instance()
		
		Thread.new { play_movie() } 
	end

	def receive_data(data)
		# should not be sent data, so hang up ?
	end
end

EventMachine::run do
	EventMachine::add_periodic_timer(2) do
		Thread.new { scan_processes() }
	end

	EventMachine::start_server("0.0.0.0", 10000, MoviePlayer)
end		
