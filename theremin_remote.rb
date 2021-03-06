require 'rubygems'
require 'device_input'
require 'curb'
require 'json'

require 'ffi'
require 'ffi/tools/const_generator'

VERSION = 0.27

config_file = File.read('config.json')
CONFIGURATION = JSON.parse(config_file)
BRIGHTNESS_SYNC_PERIOD = 20
MAX_CONCURRENT_REQUESTS = 14
REPEAT_DELAY = 20
DEBUG = !!CONFIGURATION['debug']
DEVICES = CONFIGURATION['devices']
MODE = CONFIGURATION['mode'] # "openhab" or "ha_bridge" 

HUE_RANGE = 360 # can't imagine this changing
SATURATION_RANGE = 100
MAX_BRIGHTNESS = (MODE == 'openhab' ? 100 : 255)

# curl options
CURL_EASY_OPTIONS = {:follow_location => true}
CURL_MULTI_OPTIONS = {:pipeline => Curl::CURLPIPE_HTTP1}

# for openhab HSB mapping
HUE = 0
SATURATION = 1
BRIGHTNESS = 2

# get the EVIOCGRAB constant
cg = FFI::ConstGenerator.new('input') do |gen|
  gen.include('linux/input.h')
  gen.const(:EVIOCGRAB, '%u', '(unsigned)')
end
EVIOCGRAB = cg['EVIOCGRAB'].to_i


# use two clients because the MOUSE client should wipe out any existing connections each time it sends
# this probably needs to go
CLIENTS = {
    'keyboard' => Curl::Multi,
    'mouse' => Curl::Multi
}

@px = 0.0
@py = 0.0
@state = {}

def mapped_keys
  @mapped_keys ||= CONFIGURATION['keyboard_bindings'].flat_map { |mapping| mapping['key'] }
end

class String
  def from_hsl
    self.split(',') # maps to HUE,SATURATION,BRIGHTNESS
  end
end

class Array
  def to_hsl
    self.map(&:to_i).join(',') # maps to "HUE,SATURATION,BRIGHTNESS"
  end
end

def random_color(light)
  if MODE == 'openhab'
    random_color = [(rand() * HUE_RANGE).to_i,
                    (rand() * SATURATION_RANGE).to_i,
                    brightness_of(light)].to_hsl
  else
    random_color = [rand(), rand()]
  end
end

def openhab_device_map_for(items)
  CONFIGURATION['openhab_devices'].select { |dev| dev } # TODO 
end

def color_of(key)
  if MODE == 'openhab'
    @state.dig(key.to_i, 'color', HUE).to_i
  else
    @state.dig(key.to_i, 'xy') || 0
  end
end

def all_values_of(key)
  if MODE == 'openhab'
    @state.dig(key.to_i, 'color')
  else
    @state.dig(key.to_i, 'xy') || 0
  end
end

def set_values(key, values)
  @state[key.to_i] ||= {}
  if MODE == 'openhab'
    @state[key.to_i]['color'] = values
  else
    @state[key.to_i]['xy'] = values
  end
end

def saturation_of(key)
  if MODE == 'openhab'
    @state.dig(key.to_i, 'color', SATURATION).to_i
  else
    MAX_SATURATION
  end
end

def brightness_of(key)
  if MODE == 'openhab'
    @state.dig(key.to_i, 'color', BRIGHTNESS).to_i
  else
    @state.dig(key.to_i, 'bri') || MAX_BRIGHTNESS
  end
end

def set_on_off(key, val)
  @state[key.to_i] ||= {}
  @state[key.to_i]['on'] = !!val
end

def is_on?(key)
  puts @state.to_json
  @state.dig(key.to_i, 'on') || false
end

def is_off?(key)
  !is_on?(key)
end

def has_color?(key)
  @state.has_key?(key) && (@state[key].has_key?('xy') || @state[key].has_key?('color'))
end

def set_color(key, value)
  @state[key.to_i] ||= {}
  if MODE == 'openhab'
    @state[key.to_i]['color'] ||= []
    @state[key.to_i]['color'][HUE] = value
  else
    @state[key.to_i]['xy'] = value if value.is_a?(Array) && value.length == 2 && value.all? { |v| v.is_a?(Float) }
  end
end

def set_saturation(key, value)
  @state[key.to_i] ||= {}
  if MODE == 'openhab'
    @state[key.to_i]['color'] ||= []
    @state[key.to_i]['color'][SATURATION] = value.to_i
  else
    @state[key.to_i]['bri'] = value.to_i
  end
end

def set_brightness(key, value)
  @state[key.to_i] ||= {}
  if MODE == 'openhab'
    @state[key.to_i]['color'] ||= []
    @state[key.to_i]['color'][BRIGHTNESS] = value.to_i
  else
    @state[key.to_i]['bri'] = value.to_i
  end
end

def get_state
  puts "Getting state..." if DEBUG
  if MODE == 'openhab'
    CONFIGURATION['openhab_devices'].each do |device|
      result = Curl::Easy.perform("#{CONFIGURATION['openhab_url']}/rest/items/#{device['name']}/state")
      @state[device['id']] ||= {}
      if device['type'] == 'color'
        tcolor = result.body.split(",")
        @state[device['id']].merge!({'color' => tcolor})
        @state[device['id']]['on'] = (@state[device['id']]['color'][BRIGHTNESS].to_i != 0)
      end
    end
  else
    result = Curl::Easy.perform("#{CONFIGURATION['ha_bridge_url']}/api/#{CONFIGURATION['ha_bridge_username']}/lights")
    JSON.parse(result.body).each do |k, v|
      @state[k.to_i] = v['state']
    end
  end
end

def openhab_mapping_for(light)
  # provide the label for openhab lights, for the URL, otherwise return self
  CONFIGURATION['openhab_devices'].detect { |dev| dev['id'] == light }['name']
end

def type_of(light)
  # provide the label for openhab lights, for the URL, otherwise return self
  CONFIGURATION['openhab_devices'].detect { |dev| dev['id'] == light }['type']
end

def make_dimmer_call(light, intensity)
  if MODE == 'openhab'
    {url: "#{CONFIGURATION['openhab_url']}/rest/items/#{openhab_mapping_for(light)}",
     post_fields: [color_of(light), saturation_of(light), intensity].to_hsl}
  else
    {url: "#{CONFIGURATION['ha_bridge_url']}/api/#{CONFIGURATION['ha_bridge_username']}/lights/#{light}/state",
     post_fields: {'bri' => intensity}.to_json}
  end
rescue
  nil
end

def make_color_call(light, values)
  if MODE == 'openhab'
    {url: "#{CONFIGURATION['openhab_url']}/rest/items/#{openhab_mapping_for(light)}",
     post_fields: values}
  else
    {url: "#{CONFIGURATION['ha_bridge_url']}/api/#{CONFIGURATION['ha_bridge_username']}/lights/#{light}/state",
     post_fields: {'xy': values}.to_json}
  end
rescue
  nil
end

def make_power_call(light, on_state)
  if MODE == 'openhab'
    if type_of(light) == 'echo'
      {url: "#{CONFIGURATION['openhab_url']}/rest/items/#{openhab_mapping_for(light)}",
       post_fields: (on_state ? "PLAY" : "PAUSE")}
    else
      {url: "#{CONFIGURATION['openhab_url']}/rest/items/#{openhab_mapping_for(light)}",
       post_fields: (on_state ? "ON" : "OFF")}
    end
  else
    set_brightness(light, 0) if !on_state
    {url: "#{CONFIGURATION['ha_bridge_url']}/api/#{CONFIGURATION['ha_bridge_username']}/lights/#{light}/state",
     post_fields: {'on': on_state}.to_json}
  end
rescue
  nil
end

def parallel_calls(datas, client_key)
  if datas
    m = Curl::Multi.new
    datas.flatten.compact.each do |data|
      puts "Curling #{data.class}" if DEBUG
      c = Curl::Easy.http_post(data[:url]) do |curl|
        curl.method('post')
        curl.follow_location = true
        curl.post_body = data[:post_fields]
        curl.headers['Content-Type'] = 'text/plain'
      end
      m.add(c)
    end

    m.perform
  end
end

def action_item(binding, device_name)
  
  if (binding['except'].nil? || !binding['except'].to_a.include?(device_name)) && (binding['only'].nil? || binding['only'].to_a.include?(device_name))
  puts "Executing: #{binding['name']} from #{device_name}" if binding['name'] && DEBUG

  if binding['action'] == 'reroute'
    perform_action_for(binding['substitute'], 0, device_name)
  elsif binding['action'] == 'on' || binding['action'] == 'off'
    get_state
    binding['lights'].map do |light|
      set_on_off(light, binding['action'] == 'on')
      make_power_call(light, binding['action'] == 'on')
    end
  elsif binding['action'] == 'dim'
    get_state
    binding['lights'].map do |light|
      t_bri = brightness_of(light) + (binding['value'] || 0.5)
      set_brightness(light, min_max(t_bri, 0, MAX_BRIGHTNESS))
      make_dimmer_call(light, brightness_of(light).to_i)
    end
  elsif binding['action'] == 'dim_multiply'
    get_state
    binding['lights'].map do |light|
      t_bri = brightness_of(light) * (binding['value'] || 0.5)
      set_brightness(light, min_max(t_bri, (binding['value'].to_f >= 1 ? 16 : 0), MAX_BRIGHTNESS)) # if binding-value is > 1, we mean to raise the brightness, so never let the outcome be 0
      make_dimmer_call(light, brightness_of(light))
    end
  elsif binding['action'] == 'random'
    get_state
    binding['lights'].map { |light| make_color_call(light, random_color(light)) }
  elsif binding['action'] == 'white' || binding['action'] == 'color'
    if MODE == 'ha_bridge'
      col = [0.33333333333, 0.33333333333]
      if binding['action'] == 'color'
        col[0] = binding['x'] if binding['x']
        col[1] = binding['y'] if binding['y']
      end
    elsif MODE == 'openhab'
      col = "0,0,100"
    end

    get_state
    binding['lights'].map do |light|
      if has_color?(light) && MODE == 'openhab' && type_of(light) == 'color'
        if binding['action'] == 'white'
          col = "0,0,100"
        else
          h = binding['h'] ? binding['h'] : color_of(light)
          s = binding['s'] ? binding['s'] : saturation_of(light)
          l = binding['l'] ? binding['l'] : brightness_of(light)
          col = [h, s, l].to_hsl
        end
        make_color_call(light, col)
      elsif binding['switches_on']
        make_power_call(light, true)
      end
    end.compact
  elsif binding['action'] == 'toggle'
    # Generally you wouldn't want to actually toggle everything, but rather set them all to the same thing.
    # So, this determines first if any of the lights are currently on, and if so, it turns them off.
    # Otherwise it turns them all on.
    get_state
    anything_on = binding['lights'].any? { |light| is_on?(light) }
    binding['lights'].each { |light| set_on_off(light, !anything_on) }
    binding['lights'].map { |light| make_power_call(light, !anything_on) }
  elsif binding['action'] == 'rotate'
    get_state
    target_lights = (binding['reversed'] ? binding['lights'].reverse : binding['lights'])
    values = all_values_of(target_lights.last)
    target_lights.map do |light|
      new_values = values
      values = all_values_of(light)
      set_values(light, new_values)
      make_color_call(light, MODE == 'openhab' ? new_values.to_hsl : new_values)
    end
  elsif binding['action'] == 'custom'
    new_state = binding['body']
    if binding['state_url']
      puts "Custom action #{binding['eval']}" if DEBUG
      state = JSON.parse(Curl.send((binding['state_method'] || 'get').to_sym, binding['state_url']).body)[(binding['state_variable'] || 'state')]
      puts "Current state is #{state}" if DEBUG
      new_state = eval(binding['eval'])
    end
    if binding['url'].is_a?(String)
      target = [binding['url']]
    else
      target = binding['url']
    end
    target.each { |url|  Curl.send((binding['method'] || 'post').to_sym, url, (binding['body'] || new_state).to_s) { |c| c.headers['Content-Type'] = 'text/plain' } }
    nil
  elsif binding['action'] == 'exec'
    system(item['exec'])
    nil
  elsif binding['chain']
    binding['chain'].map { |chain| action_item(chain, device_name) }
  end.to_a.compact
  end
end

def perform_action_for(key, code = 0, device_name)
  bindings = CONFIGURATION['keyboard_bindings'].select { |item| item['key'] == key || (item['key'].is_a?(Array) && item['key'].include?(key)) }
  bindings.flat_map { |binding| action_item(binding, device_name) if code == 0 }.compact
end

def min_max(val, min, max)
  a = val < min ? min : val
  a > max ? max : a
end

def mouse_xy(event)
  get_state
  CONFIGURATION['mouse_binding']['lights'].map do |light|
    new_x = new_y = 0
    if (event.code == "X")
      new_x = color_of(light)[0] + (event.data.value.to_f / CONFIGURATION['max_x_resolution'])
      new_y = color_of(light)[1]
    end
    if (event.code == "Y")
      new_x = color_of(light)[0]
      new_y = color_of(light)[1] - (event.data.value.to_f / CONFIGURATION['max_y_resolution']) # the operator is a - because Y is inverted (0,0 is the top left corner)
    end
    if CONFIGURATION['drift']
      new_x += (rand() * CONFIGURATION['drift'] * 2) - CONFIGURATION['drift']
      new_y += (rand() * CONFIGURATION['drift'] * 2) - CONFIGURATION['drift']
    end
    new_xy = [min_max(new_x, 0, 1.0).to_i, min_max(new_y, 0, 1.0).to_i]
    set_color(light, new_xy)
    make_color_call(light, new_xy)
  end
end

def mouse_hsl(event)
  get_state
  CONFIGURATION['mouse_binding']['lights'].map do |light|
    new_h = new_s = 0
    if (event.code == "X")
      new_h = color_of(light) + 360 * (event.data.value.to_f / CONFIGURATION['max_x_resolution'])
      new_s = saturation_of(light)
    end
    if (event.code == "Y")
      new_h = color_of(light)
      new_s = saturation_of(light) + 100 * (event.data.value.to_f / CONFIGURATION['max_y_resolution'])
    end
    if CONFIGURATION['drift']
      new_h += (rand() * CONFIGURATION['drift'] * 2) - CONFIGURATION['drift']
      new_s += (rand() * CONFIGURATION['drift'] * 2) - CONFIGURATION['drift']
    end
    new_hue = min_max(new_h, 0, 359.99)
    new_saturation = min_max(new_s, 0, 100.0)
    new_brightness = brightness_of(light)

    set_color(light, new_hue)
    set_saturation(light, new_saturation)
    make_color_call(light, [new_hue, new_saturation, new_brightness].to_hsl)
  end
end

def input_monitor(device)
  if File.readable?(device)
    dev = File.new(device)
    begin
      dev.ioctl(EVIOCGRAB, 1) # prevent other things from listening to the device
    rescue
    end
    DeviceInput.read_loop(dev) do |event|
      puts "Received #{event}" if DEBUG
      if event.type == 'EV_KEY' && !CONFIGURATION['keyboard_disabled'] # KEYBOARD DEVICES
        puts "Received: #{event.code}" if DEBUG
        if mapped_keys.include?(event.code)
          calls = parallel_calls(perform_action_for(event.code, event.data.value, device), 'keyboard')
        else
          puts "#{event.code} is not a mapped key" if DEBUG
        end
      elsif !CONFIGURATION['mouse_disabled']
        puts "Moved by #{event.data.value.to_f}" if (event.code == "X" || event.code == "Y") if DEBUG
        puts "Mouse action: #{event}" if DEBUG

        if event.code == 'Wheel'
          parallel_calls(perform_action_for("Wheel#{event.data.value == -1 ? "Down" : "Up"}", 0, device), 'keyboard')
        elsif !CONFIGURATION['mouse_movements_disabled'] && (['X', 'Y'].include?(event.code))  
          if CONFIGURATION['mouse_effect'] == 'xy'
            calls = mouse_xy(event)
          elsif CONFIGURATION['mouse_effect'] != 'none'
            calls = mouse_hsl(event)
          end
        end
        parallel_calls(calls, 'mouse')
      end
    end
  else
    puts "Device #{device} could not be read, skipping"
    false
  end
end

def start
  puts "Bound keys: #{mapped_keys.join(",")}" if DEBUG
  threads = []
  DEVICES.each_index do |i|
    threads.push(Thread.new(i) do
      puts "Adding device #{DEVICES[i]}" if DEBUG
      loop do
        begin
          break if !input_monitor(DEVICES[i])
        rescue => e
          puts "** ERROR! #{e.message} **"
          puts e.backtrace.join("\n")
          puts "** END OF ERROR **"
        end
      end
    end)
  end
  DEVICES.each_index { |i| threads[i].join }
end

start
