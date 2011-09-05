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

# FileHandler is responsible for reading from the ttyrec files and sending
# each frame off to the TimeFilter thread.
#
# XXX - convert this to pure reading and not use notification.. bit racy etc.
#
# This converts from absolute time of day format to relative to beginning of
# file.

module FileHandler
	def process_frames
		fp = open(path, "r")
		fp.seek(@offset)

		while(true) do
			header = fp.read(12)
			return if header.nil?

			t1, t2, len = header.unpack("VVV")
		
			ts = Float(t1) + (Float(t2) / 1000000) # XXX, Float?

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

	# filter_queue reads from a file-reader Queue and divides those
	# into chunks based on relative timestamp / SECONDS. Those are
	# a suitable clip for movie maker to dosh out. 
	#
	# It also converts from relative time stamps to delay based (delay
	# needed to sleep for proper play back)

	def filter_queue()
		clips = [] 

		while(true) 
			timestamp, data = @queue.pop()
			break if timestamp.nil?	# End of File :>

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
		@MM.push(clip)
	end

end

#
# MovieMaker is responsible for distributing the clips to MoviePlayer 
# instances, ensuring that there is something in the queue if there are
# readers, etc.
#

class MovieMaker
	include Singleton
	attr_accessor :clips

	def initialize
		@clips = Queue.new()
		@oldclips = []
		Thread.new { play_old_clips }
	end

	def push(item)
		@clips.push(item)

		@oldclips.shift() if @oldclips.length >= 8
		@oldclips.push(item)
	end

	def play_old_clips
		while(true)
			select(nil, nil, nil, 1)
			if(@clips.empty?) then
				next if @oldclips.size == 0

				@clips.num_waiting().times do
					@clips.push(@oldclips[rand(@oldclips.size)])
				end
			end

		end
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
