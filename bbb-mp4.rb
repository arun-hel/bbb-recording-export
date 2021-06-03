require "trollop"
require 'nokogiri'
require 'base64'
require 'zlib'
require File.expand_path('../../../lib/recordandplayback', __FILE__)

opts = Trollop.options do
  opt :meeting_id, "Meeting id to archive", type: String
  opt :format, "Playback format name", type: String
end

meeting_id = opts[:meeting_id]

logger = Logger.new("/var/log/bigbluebutton/post_publish.log", 'weekly')
logger.level = Logger::INFO
BigBlueButton.logger = logger

published_files = "/var/bigbluebutton/published/presentation/#{meeting_id}"
mp4_location = "/mnt/scalelite-recordings/var/bigbluebutton/mp4"

# Main code
# ================= render chat ===================
start = Time.now
BigBlueButton.logger.info("Starting render_chat.rb for [#{meeting_id}]")

# Opens slides_new.xml
@chat = Nokogiri::XML(File.open("#{published_files}/slides_new.xml"))
@meta = Nokogiri::XML(File.open("#{published_files}/metadata.xml"))

# Get chat messages and timings
recording_duration = (@meta.xpath('//duration').text.to_f / 1000).round(0)

ins = @chat.xpath('//@in').to_a.map(&:to_s).unshift(0).push(recording_duration)

# Creates directory for the temporary assets
Dir.mkdir("#{published_files}/chats") unless File.exist?("#{published_files}/chats")
Dir.mkdir("#{published_files}/timestamps") unless File.exist?("#{published_files}/timestamps")

# Creates new file to hold the timestamps of the chat
File.open("#{published_files}/timestamps/chat_timestamps", 'w') {}

chat_intervals = []

ins.each_cons(2) do |(a, b)|
  chat_intervals << [a, b]
end

messages = @chat.xpath("//chattimeline[@target=\"chat\"]")

# Line break offset
dy = 0

# Empty string to build <text>...</text> tag from
text = ""
message_heights = [0]

messages.each do |message|
    # User name and chat timestamp
    text += "<text x=\"2.5\" y=\"12.5\" dy=\"#{dy}em\" font-family=\"monospace\" font-size=\"15\" font-weight=\"bold\">#{message.attr('name')}</text>"
    text += "<text x=\"2.5\" y=\"12.5\" dx=\"#{message.attr('name').length}em\" dy=\"#{dy}em\" font-family=\"monospace\" font-size=\"15\" fill=\"grey\" opacity=\"0.5\">#{Time.at(message.attr('in').to_f.round(0)).utc.strftime('%H:%M:%S')}</text>"

    line_breaks = message.attr('message').chars.each_slice(35).map(&:join)
    message_heights.push(line_breaks.size + 2)

    dy += 1

    # Message text
    line_breaks.each do |line|
        text += "<text x=\"2.5\" y=\"12.5\" dy=\"#{dy}em\" font-family=\"monospace\" font-size=\"15\">#{line}</text>"
        dy += 1
    end

    dy += 1
end

base = -840

# Create SVG chat with all messages for debugging purposes
# builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
#     xml.doc.create_internal_subset('svg', '-//W3C//DTD SVG 1.1//EN', 'http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd')
#     xml.svg(width: '320', height: dy * 15, version: '1.1', 'xmlns' => 'http://www.w3.org/2000/svg', 'xmlns:xlink' => 'http://www.w3.org/1999/xlink') do
#         xml << text
#     end
# end

# File.open("#{published_files}/chats/chat.svg", 'w') do |file|
#     file.write(builder.to_xml)
# end

chat_intervals.each.with_index do |frame, chat_number|
    interval_start = frame[0]
    interval_end = frame[1]

    base += message_heights[chat_number] * 15

    # Create SVG chat window
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.doc.create_internal_subset('svg', '-//W3C//DTD SVG 1.1//EN', 'http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd')
        xml.svg(width: '320', height: '840', viewBox: "0 #{base} 320 840", version: '1.1', 'xmlns' => 'http://www.w3.org/2000/svg', 'xmlns:xlink' => 'http://www.w3.org/1999/xlink') do
            xml << text
        end
    end

    # Saves frame as SVGZ file
    File.open("#{published_files}/chats/chat#{chat_number}.svgz", 'w') do |file|
        svgz = Zlib::GzipWriter.new(file)
        svgz.write(builder.to_xml)
        svgz.close
    end

    # # Saves frame as SVG file (for debugging purposes)
    # File.open("#{published_files}/chats/chat#{chat_number}.svg", 'w') do |file|
    #     file.write(builder.to_xml)
    # end

    File.open("#{published_files}/timestamps/chat_timestamps", 'a') do |file|
        file.puts "file #{published_files}/chats/chat#{chat_number}.svgz"
        file.puts "duration #{(interval_end.to_f - interval_start.to_f).round(1)}"
    end
end

# Benchmark
finish = Time.now
BigBlueButton.logger.info("Finished render_chat.rb for [#{meeting_id}]. Total: #{finish - start}")

# =========================== Render cursor ===========================

BigBlueButton.logger.info("Starting render_cursor.rb for [#{meeting_id}]")
start = Time.now
# Opens cursor.xml and shapes.svg
@doc = Nokogiri::XML(File.open("#{published_files}/cursor.xml"))
@img = Nokogiri::XML(File.open("#{published_files}/shapes.svg"))
@pan = Nokogiri::XML(File.open("#{published_files}/panzooms.xml"))

# Get intervals to display the frames
timestamps = @doc.xpath('//@timestamp')

intervals = timestamps.to_a.map(&:to_s).map(&:to_f).uniq

# Creates directory for the temporary assets
Dir.mkdir("#{published_files}/cursor") unless File.exist?("#{published_files}/cursor")

# Creates new file to hold the timestamps of the cursor's position
File.open("#{published_files}/timestamps/cursor_timestamps", 'w') {}

# Obtain interval range that each frame will be shown for
frame_number = 0
frames = []

intervals.each_cons(2) do |(a, b)|
    frames << [a, b]
end

# Obtains all cursor events
cursor = @doc.xpath('//event/cursor', 'xmlns' => 'http://www.w3.org/2000/svg')

frames.each do |frame|
    interval_start = frame[0]
    interval_end = frame[1]

    # Query to figure out which slide we're on - based on interval start since slide can change if mouse stationary
    slide = @img.xpath("(//xmlns:image[@in <= #{interval_start}])[last()]", 'xmlns' => 'http://www.w3.org/2000/svg')

    # Query viewBox parameter of slide
    view_box = @pan.xpath("(//event[@timestamp <= #{interval_start}]/viewBox/text())[last()]")

    width = slide.attr('width').to_s
    height = slide.attr('height').to_s

    x = slide.attr('x').to_s
    y = slide.attr('y').to_s

    # Get cursor coordinates
    pointer = cursor[frame_number].text.split

    cursor_x = (pointer[0].to_f * width.to_f).round(3)
    cursor_y = (pointer[1].to_f * height.to_f).round(3)

    # Builds SVG frame
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        # xml.doc.create_internal_subset('svg', '-//W3C//DTD SVG 1.1//EN', 'http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd')

        xml.svg(width: "1600", height: "1080", x: x, y: y, version: '1.1', viewBox: view_box, 'xmlns' => 'http://www.w3.org/2000/svg') do
            xml.circle(cx: cursor_x, cy: cursor_y, r: '10', fill: 'red') unless cursor_x.negative? || cursor_y.negative?
        end
    end

    # Saves frame as SVGZ file
    File.open("#{published_files}/cursor/cursor#{frame_number}.svgz", 'w') do |file|
        svgz = Zlib::GzipWriter.new(file)
        svgz.write(builder.to_xml)
        svgz.close
    end

    # Writes its duration down
    File.open("#{published_files}/timestamps/cursor_timestamps", 'a') do |file|
        file.puts "file #{published_files}/cursor/cursor#{frame_number}.svgz"
        file.puts "duration #{(interval_end - interval_start).round(1)}"
    end

    frame_number += 1
end

# The last image needs to be specified twice, without specifying the duration (FFmpeg quirk)
File.open("#{published_files}/timestamps/cursor_timestamps", 'a') do |file|
    file.puts "file #{published_files}/cursor/cursor#{frame_number - 1}.svgz"
end

finish = Time.now
BigBlueButton.logger.info("Finished render_cursor.rb for [#{meeting_id}]. Total: #{finish - start}")

# =========================== render whiteboard ===========================
BigBlueButton.logger.info("Starting render_whiteboard.rb for [#{meeting_id}]")
start = Time.now
# Opens shapes.svg
@doc = Nokogiri::XML(File.open("#{published_files}/shapes.svg"))

# Opens panzooms.xml
@pan = Nokogiri::XML(File.open("#{published_files}/panzooms.xml"))

# Get intervals to display the frames
ins = @doc.xpath('//@in')
outs = @doc.xpath('//@out')
timestamps = @doc.xpath('//@timestamp')
undos = @doc.xpath('//@undo')
images = @doc.xpath('//xmlns:image', 'xmlns' => 'http://www.w3.org/2000/svg')
zooms = @pan.xpath('//@timestamp')

intervals = (ins + outs + timestamps + undos + zooms).to_a.map(&:to_s).map(&:to_f).uniq.sort

# Image paths need to follow the URI Data Scheme (for slides and polls)
images.each do |image|
  path = "#{published_files}/#{image.attr('xlink:href')}"

  # Open the image
  data = File.open(path).read

  image.set_attribute('xlink:href', "data:image/#{File.extname(path).delete('.')};base64,#{Base64.encode64(data)}")
  image.set_attribute('style', 'visibility:visible')
end

# Convert XHTML to SVG so that text can be shown
xhtml = @doc.xpath('//xmlns:g/xmlns:switch/xmlns:foreignObject', 'xmlns' => 'http://www.w3.org/2000/svg')

xhtml.each do |foreign_object|
  # Get and set style of corresponding group container
  g = foreign_object.parent.parent

  text = foreign_object.children.children

  # Obtain X and Y coordinates of the text
  x = foreign_object.attr('x').to_s
  y = foreign_object.attr('y').to_s
  text_color = g.attr('style').split(';').first.split(':')[1]

  # Preserve the whitespace (seems to be ignored by FFmpeg)
  svg = "<text x=\"#{x}\" y=\"#{y}\" xml:space=\"preserve\" fill=\"#{text_color}\">"

  # Add line breaks as <tspan> elements
  text.each do |line|
    if line.to_s == "<br/>"

      svg += "<tspan x=\"#{x}\" dy=\"0.9em\"><br/></tspan>"

    else

      # Make a new line every 40 characters (arbitrary value, SVG does not support auto wrap)
      line_breaks = line.to_s.chars.each_slice(40).map(&:join)

      line_breaks.each do |row|
        svg += "<tspan x=\"#{x}\" dy=\"0.9em\">#{row}</tspan>"
      end

    end
  end

  svg += "</text>"

  g.add_child(svg)

  # Remove the <switch> tag
  foreign_object.parent.remove
end

# Creates directory for the temporary assets
Dir.mkdir("#{published_files}/frames") unless File.exist?("#{published_files}/frames")

# Creates new file to hold the timestamps of the whiteboard
File.open("#{published_files}/timestamps/whiteboard_timestamps", 'w') {}

# Intervals with a value of -1 do not correspond to a timestamp
intervals = intervals.drop(1) if intervals.first == -1

# Obtain interval range that each frame will be shown for
frame_number = 0
frames = []

intervals.each_cons(2) do |(a, b)|
  frames << [a, b]
end

# Render the visible frame for each interval
frames.each do |frame|
  interval_start = frame[0]
  interval_end = frame[1]

  # Query slide we're currently on
  slide = @doc.xpath("//xmlns:image[@in <= #{interval_start} and #{interval_end} <= @out]", 'xmlns' => 'http://www.w3.org/2000/svg')

  # Query current viewbox parameter
  view_box = @pan.xpath("(//event[@timestamp <= #{interval_start}]/viewBox/text())[last()]")

  # Get slide information
  slide_id = slide.attr('id').to_s

  width = slide.attr('width').to_s
  height = slide.attr('height').to_s
  x = slide.attr('x').to_s
  y = slide.attr('y').to_s

  draw = @doc.xpath(
    "//xmlns:g[@class=\"canvas\" and @image=\"#{slide_id}\"]/xmlns:g[@timestamp < \"#{interval_end}\" and (@undo = \"-1\" or @undo >= \"#{interval_end}\")]", 'xmlns' => 'http://www.w3.org/2000/svg'
  )

  # Builds SVG frame
  builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
    xml.doc.create_internal_subset('svg', '-//W3C//DTD SVG 1.1//EN', 'http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd')

    xml.svg(width: "1600", height: "1080", x: x, y: y, version: '1.1', viewBox: view_box, 'xmlns' => 'http://www.w3.org/2000/svg', 'xmlns:xlink' => 'http://www.w3.org/1999/xlink') do
      # Display background image
      xml.image('xlink:href': slide.attr('href'), width: width, height: height, preserveAspectRatio: "xMidYMid slice", x: x, y: y, style: slide.attr('style'))

      # Add annotations
      draw.each do |shape|
        # Make shape visible
        style = shape.attr('style')
        style.sub! 'hidden', 'visible'

        xml.g(style: style) do
          xml << shape.xpath('./*').to_s
        end
      end
    end
  end

  # Saves frame as SVG file (for debugging purposes)
  # File.open("#{published_files}/frames/frame#{frame_number}.svg", 'w') do |file|
  # file.write(builder.to_xml)
  # end

  # Writes its duration down
  # File.open("#{published_files}/timestamps/whiteboard_timestamps", 'a') do |file|
  # file.puts "file #{published_files}/frames/frame#{frame_number}.svg"
  # file.puts "duration #{(interval_end - interval_start).round(1)}"
  # end

  # Saves frame as SVGZ file
  File.open("#{published_files}/frames/frame#{frame_number}.svgz", 'w') do |file|
    svgz = Zlib::GzipWriter.new(file)
    svgz.write(builder.to_xml)
    svgz.close
  end

  # Writes its duration down
  File.open("#{published_files}/timestamps/whiteboard_timestamps", 'a') do |file|
    file.puts "file ../frames/frame#{frame_number}.svgz"
    file.puts "duration #{(interval_end - interval_start).round(1)}"
  end

  frame_number += 1
  # puts frame_number
end

# The last image needs to be specified twice, without specifying the duration (FFmpeg quirk)
File.open("#{published_files}/timestamps/whiteboard_timestamps", 'a') do |file|
  file.puts "file #{published_files}/frames/frame#{frame_number - 1}.svgz"
end

# Benchmark
finish = Time.now

BigBlueButton.logger.info("Finished render_whiteboard.rb for [#{meeting_id}]. Total: #{finish - start}")

start = Time.now

# Determine file extensions used
extension = if File.file?("#{published_files}/video/webcams.mp4")
  "mp4"
else
  "webm"
            end

# Determine if video had screensharing
deskshare = File.file?("#{published_files}/deskshare/deskshare.#{extension}")

if deskshare
  render = "ffmpeg -f lavfi -i color=c=white:s=1920x1080 " \
 "-f concat -safe 0 -i #{published_files}/timestamps/whiteboard_timestamps " \
 "-f concat -safe 0 -i #{published_files}/timestamps/cursor_timestamps " \
 "-f concat -safe 0 -i #{published_files}/timestamps/chat_timestamps " \
 "-i #{published_files}/video/webcams.#{extension} " \
 "-i #{published_files}/deskshare/deskshare.#{extension} -filter_complex " \
"'[4]scale=w=320:h=240[webcams];[5]scale=w=1600:h=1080:force_original_aspect_ratio=1[deskshare];[0][deskshare]overlay=x=320[screenshare];[screenshare][1]overlay=x=320[whiteboard];[whiteboard][2]overlay=x=320[cursor];[cursor][3]overlay[chat];[chat][webcams]overlay' " \
"-c:a aac -shortest -y #{mp4_location}/#{meeting_id}.mp4"
else
  render = "ffmpeg -nostats -f lavfi -i color=c=white:s=1920x1080 " \
"-f concat -safe 0 -i #{published_files}/timestamps/whiteboard_timestamps " \
 "-f concat -safe 0 -i #{published_files}/timestamps/cursor_timestamps " \
 "-f concat -safe 0 -i #{published_files}/timestamps/chat_timestamps " \
 "-i #{published_files}/video/webcams.#{extension} -filter_complex " \
 "'[4]scale=w=320:h=240[webcams];[0][1]overlay=x=320[slides];[slides][2]overlay=x=320[cursor];[cursor][3]overlay=y=240[chat];[chat][webcams]overlay' " \
 "-c:a aac -shortest -y #{mp4_location}/#{meeting_id}.mp4"
end

BigBlueButton.logger.info("Beginning to render video for [#{meeting_id}]")
system(render)

finish = Time.now
BigBlueButton.logger.info("Exported recording available at #{mp4_location}/#{meeting_id}.mp4, Render time: #{finish - start}")

# Delete the contents of the scratch directories (race conditions)
# FileUtils.rm_rf("#{published_files}/chats")
# FileUtils.rm_rf("#{published_files}/cursor")
# FileUtils.rm_rf("#{published_files}/frames")
# FileUtils.rm_rf("#{published_files}/timestamps")

exit 0
