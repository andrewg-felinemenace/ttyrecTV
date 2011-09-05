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
			@basets = ts

			$logger.debug("length is #{len}, adjusted timestamp is #{adj_ts}")
		

			data = fp.read(len)
			return if data.nil?

			#print data

			@offset += 12 + len

			# well, I lied.
			@MM.add_frames(path, [ adj_ts, data ])
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
			if(@lock.try_lock()) then
				process_frames() 
			end
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

	def debug_clip(clip)
		$logger.debug("okay, clip is #{clip.class}, with #{clip.length} entries")

		max = clip.length
		prev = 0
		clip.each { |timestamp, data|
			delay = timestamp - prev

			# puts "data is #{data.class}"
			$logger.debug("delay of #{delay}, data.length = #{data.length}")
			print data

			select(nil, nil, nil, delay)
			prev = timestamp
		}

	end

	def make_clip(filename, frames)
		$logger.debug("Making clips from #{filename}")	
		clips = []
		base = frames[0][0]
		prev = 0

		clip = []
		frames.each { |ts, data|
			idx = (ts - base) / SECONDS
			idx = idx.round

			$logger.debug("index of #{idx}")

			if(idx > prev) then
				prev = idx
				# yay, full clip
				$logger.debug("full clip!")
		
				# XXX, rewrite		
				clips << clip
				clip = []
			end

			clip << [ts, data]
		}

		puts clips.inspect

		# Calculate frames to delete
		ctd = 0
		clips.each { |clip|
			ctd += clip.length # frame length
		}		

		# play clip
		clips.each { |clip|
			debug_clip(clip)
		}

	end

	def make_movies()
		while (true)
			@partial.each { |k, v| 
				start = v[0][0]
				stop = v[-1][0]

				$logger.debug("#{k} #{stop} - #{start} = #{stop - start}")

				next if ((stop - start) < SECONDS)


				clip, ftd = make_clip(k, v)				
				# delete first ftd frames

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

	def unbind()
		# unregister consumation :>
	end
end

EventMachine::run do
	EventMachine::add_periodic_timer(2) do
		Thread.new { scan_processes() }
	end

	EventMachine::start_server("0.0.0.0", 10000, MoviePlayer)
end		
