require 'faraday'
require 'json'
require 'rpi_gpio'

# always flush STDOUT immediately
$stdout.sync = true

Metric = Struct.new(:name, :percent, :led_pin)
ClusterMetrics = Struct.new(:cpu, :mem, :disk)

# GPIO pins
SERVO = 3
BLUE_LED = 5
GREEN_LED = 7
YELLOW_LED = 11
RED_LED = 13
PWM_FREQ = 50
SERVO_RANGE = 180

# calls new relic to find cluster metrics
# returns nil if it fails
def call_new_relic
  puts "Calling new relic"
  account_id = ENV['NEW_RELIC_ACCOUNT_ID']
  query = ENV['INSIGHTS_QUERY']
  headers =  { 
    'X-Query-Key' => ENV['NEW_RELIC_INSIGHTS_QUERY_KEY'],
    'Accept' => 'application/json'
  }
  url = "https://insights-api.newrelic.com/v1/accounts/#{account_id}/query?nrql=#{query}"
  puts "calling #{url}"
  response = Faraday.get(url, nil, headers)
  unless response.success?
    "Failed to call new relic! Received status: #{response.status} and body #{response.body}" 
    throw Exception
  end
  event = JSON.parse(response.body)['results'].first['events'].first
  mem = (event['mem.percent'] * 100).ceil
  cpu = (event['cpus.percent'] * 100).ceil
  disk = (event['disk.percent'] * 100).ceil
  metrics = ClusterMetrics.new(
    Metric.new('cpu', cpu, BLUE_LED),
    Metric.new('memory', mem, GREEN_LED),
    Metric.new('disk', disk, YELLOW_LED)
  )
  puts "mem: #{metrics.mem}, cpu: #{metrics.cpu}, disk: #{metrics.disk}"
  metrics
end

def get_metrics
  begin
    metrics = call_new_relic
  rescue => e
    puts "Failed calling new relic"
    puts e
    # turn on red light to denote error
    turn_off_all_leds
    critical_light(100)
    return nil
  end
  metrics
end

def worst_metric(metrics)
  [metrics.cpu, metrics.mem, metrics.disk].max_by(&:percent)
end

def critical_light(percent)
  if percent >= 95
    puts "metric at critical percent #{percent}"
    RPi::GPIO.set_high RED_LED
  else
    puts "metric not at critical percent: #{percent}"
    RPi::GPIO.set_low RED_LED
  end
end

def turn_on_led(pin)
  puts "Turning on LED at pin #{pin}"
  # turn off everything
  RPi::GPIO.set_low BLUE_LED
  RPi::GPIO.set_low GREEN_LED
  RPi::GPIO.set_low YELLOW_LED
  # turn on the one we want
  RPi::GPIO.set_high pin
end

def turn_on_all_leds
  RPi::GPIO.set_high BLUE_LED
  RPi::GPIO.set_high GREEN_LED
  RPi::GPIO.set_high YELLOW_LED
  RPi::GPIO.set_high RED_LED
end

def turn_off_all_leds
  RPi::GPIO.set_low BLUE_LED
  RPi::GPIO.set_low GREEN_LED
  RPi::GPIO.set_low YELLOW_LED
  RPi::GPIO.set_low RED_LED
end

def set_angle(pwm, angle)
  # 2.5 is the minimum, a.k.a. 0 degrees
  duty = angle / 18 + 2.5
  puts "Setting servo to #{angle} degrees with duty cycle #{duty}"
  # continuosly move towards the desired angle
  pwm.duty_cycle = duty
  # let it get to the angle
  sleep(1)
  # stop moving
  pwm.duty_cycle = 0
end

def move_servo_to_percent(pwm, percent)
  angle = 180 - ((percent / 100.0) * SERVO_RANGE).ceil
  set_angle(pwm, angle)
end

def setup
  puts "setting up pins"
  RPi::GPIO.set_warnings(false)
  RPi::GPIO.set_numbering :board
  RPi::GPIO.setup SERVO, :as => :output, :initialize => :low
  RPi::GPIO.setup BLUE_LED, :as => :output, :initialize => :low
  RPi::GPIO.setup GREEN_LED, :as => :output, :initialize => :low
  RPi::GPIO.setup YELLOW_LED, :as => :output, :initialize => :low
  RPi::GPIO.setup RED_LED, :as => :output, :initialize => :low
  pwm = RPi::GPIO::PWM.new(SERVO, PWM_FREQ)
  pwm.start(0)
  puts "setting arm to 0"
  set_angle(pwm, SERVO_RANGE)
  pwm
end

def teardown(pwm)
  puts "tearing down"
  puts "setting arm to 0"
  set_angle(pwm, SERVO_RANGE)
  pwm.stop
  RPi::GPIO.set_low BLUE_LED
  RPi::GPIO.set_low GREEN_LED
  RPi::GPIO.set_low YELLOW_LED
  RPi::GPIO.set_low RED_LED
end

def display_metric(pwm, metric)
  puts "displaying #{metric}"
  turn_on_led(metric.led_pin)
  critical_light(metric.percent)
  move_servo_to_percent(pwm, metric.percent)
end

def debug(pwm)
  puts "testing LEDs"
  turn_on_all_leds
  metrics = get_metrics
  turn_off_all_leds
  
  unless metrics.nil?
    puts "testing servo"
    display_metric(pwm, metrics.cpu)
    sleep(5)
    display_metric(pwm, metrics.disk)
    sleep(5)
    display_metric(pwm, metrics.mem)
    sleep(5)
  end

  puts "testing normal workflow"
  update_display(pwm)
  sleep(60)
end

def update_display(pwm)
  puts "updating metrics"
  metrics = get_metrics
  display_metric(pwm, worst_metric(metrics)) unless metrics.nil?
end

begin 
  pwm = setup
  if ENV['DEBUG'] == 'true'
    debug(pwm)
  else
    while true
      update_display(pwm)
      seconds_to_sleep = ENV['SLEEP_SECONDS'] || '43200'
      puts "Sleeping #{seconds_to_sleep} seconds"
      sleep(seconds_to_sleep.to_i)
    end
  end
ensure
  teardown(pwm)
end

puts "done."
