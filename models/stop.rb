require 'date'

class Stop

  attr_accessor :data, :time

  def initialize(stop_id)
    @stop_id = stop_id
    @time = Time.now
    load_name
    get_data
  end

  STOP_INFO_URI = 'http://api.pugetsound.onebusaway.org/api/where/stop/%s.json?key=%s'

  def load_name
    stop_url = URI.parse(sprintf(STOP_INFO_URI, @stop_id, KEY))
    stop_req = Net::HTTP::Get.new(stop_url.to_s)
    stop_res = Net::HTTP.start(stop_url.host, stop_url.port) do |http| 
      http.request(stop_req)
    end

    raise "couldn't fetch stop info!" if /^4/.match(stop_res.code)

    blob = JSON.load(stop_res.body)
    raise "no data returned for stop info!" unless data = blob['data']

    @code = data['entry']['code']
    @name = data['entry']['name']
  end

  REFRESH_PERIOD = 60 # seconds

  @@instances = {}

  def self.routes_for_stop_id(stop_id)
    if stop = @@instances[stop_id]
      now = Time.now
      if now - stop.time > REFRESH_PERIOD
        puts "reloading stop data"
        @@instances[stop_id] = self.new(stop_id)
      else
        puts "using old instance"
        stop
      end
    else
      puts "loading new stop data"
      @@instances[stop_id] = self.new(stop_id)
    end
  end

  ROUTE_INFO_URI =
    'http://api.pugetsound.onebusaway.org/api/where/route/%s.json?key=%s'

  KEY = IO.read('oba_rest_key.txt').strip

  def get_data
    routes = get_routes
    routes_blob = routes.map { |route|
      wait_times = route.arrival_times.take(3).map do |arrival_time|
        {
          'wait' => ((arrival_time.time - Time.now) / 60).round,
          'current' => arrival_time.current
        }
      end

      {
        'number' => route.number,
        'description' => route.headsign,
        'wait_times' => wait_times
      }
    }.sort_by { |route| 
      route['wait_times'].first['wait']
    }.each { |route|
      route['wait_times'].each { |wait| wait['wait'] = [0, wait['wait']].max }
    }

    @data = { 
      'id' => @code,
      'name' => @name,
      'routes' => routes_blob
    }

    self
  end

  ArrivalTime = Struct.new(:time, :current)
  Route = Struct.new(:number, :headsign, :arrival_times)

  def get_routes
    arrivals = get_arrivals
    routes = Hash.new

    arrivals.each do |arrival|

      route = 
        if routes[arrival.route_id]
          routes[arrival.route_id]
        else
          route_url = URI.parse(sprintf(ROUTE_INFO_URI, arrival.route_id, KEY))
          route_req = Net::HTTP::Get.new(route_url.to_s)
          route_res = Net::HTTP.start(route_url.host, route_url.port) do |http| 
            http.request(route_req)
          end

          route_info_blob = JSON.load(route_res.body)

          if route_data = route_info_blob['data']
            routes[arrival.route_id] = 
              Route.new(route_data['entry']['shortName'],
                        route_data['entry']['description'],
                        [])
          else
            nil
          end
        end

      next unless route

      route.arrival_times << ArrivalTime.new(arrival.time, arrival.current)
    end

    routes.values
  end

  Arrival = Struct.new(:route_id, :current, :time)

  ARRIVALS_URI = 'http://api.pugetsound.onebusaway.org/api/where/arrivals-and-departures-for-stop/%s.json?key=%s&minutesAfter=60'

  def get_arrivals
    url = URI.parse(sprintf(ARRIVALS_URI, @stop_id, KEY))
    req = Net::HTTP::Get.new(url.to_s)
    res = Net::HTTP.start(url.host, url.port) { |http| http.request(req) }

    raise "couldn't connect to OBA!" if /^4/.match(res.code)

    body_blob = JSON.load(res.body)
    raise "no data; maybe bad stop ID?" unless data_blob = body_blob['data']

    data_blob['entry']['arrivalsAndDepartures'].map do |arrival_blob|
      arrival = Arrival.new(arrival_blob['routeId'])

      if arrival_blob['predicted']
        arrival.current = true
        arrival.time = Time.at(arrival_blob['predictedArrivalTime'] / 1000)
      else
        arrival.current = false
        arrival.time = Time.at(arrival_blob['scheduledArrivalTime'] / 1000)
      end

      arrival
    end
  end

end
