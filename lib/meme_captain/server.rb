require 'digest/sha1'

require 'json'
require 'rack'
require 'sinatra/base'

module MemeCaptain

  class Server < Sinatra::Base

    set :root, File.expand_path(File.join('..', '..'), File.dirname(__FILE__))
    set :source_img_max_side, 800
    set :watermark, Magick::ImageList.new(File.expand_path(
      File.join('..', '..', 'watermark.png'), File.dirname(__FILE__)))

    get '/' do
      @u = params[:u]

      @t1 = params[:t1]
      @t1x = params[:t1x]
      @t1y = params[:t1y]
      @t1w = params[:t1w]
      @t1h = params[:t1h]

      @t2 = params[:t2]
      @t2x = params[:t2x]
      @t2y = params[:t2y]
      @t2w = params[:t2w]
      @t2h = params[:t2h]

      @root_url = url('/')

      erb :index
    end

    def convert_metric(metric, default)
      case
        when metric.to_s.empty?; default
        when metric.index('.'); metric.to_f
        else; metric.to_i
      end
    end

    def normalize_params(p)
      result = {
        'u' => p[:u],

         # convert to empty string if null
        't1'  => p[:t1].to_s,
        't2'  => p[:t2].to_s,
      }

      result['t1x'] = convert_metric(p[:t1x], 0.05)
      result['t1y'] = convert_metric(p[:t1y], 0)
      result['t1w'] = convert_metric(p[:t1w], 0.9)
      result['t1h'] = convert_metric(p[:t1h], 0.25)

      result['t2x'] = convert_metric(p[:t2x], 0.05)
      result['t2y'] = convert_metric(p[:t2y], 0.75)
      result['t2w'] = convert_metric(p[:t2w], 0.9)
      result['t2h'] = convert_metric(p[:t2h], 0.25)

      # if the id of an existing meme is passed in as the source url, use the
      # source image of that meme for the source image
      if result['u'][%r{^[a-f0-9]+\.(?:gif|jpg|png)$}]
        if existing_as_source = MemeData.find_by_meme_id(result['u'])
          result['u'] = existing_as_source.source_url
        end
      end

      # hash with string keys that can be accessed by symbol
      Hash.new { |hash,key| hash[key.to_s] if Symbol === key }.merge(result)
    end

    def gen(p)
      norm_params = normalize_params(p)

      if existing = MemeData.first(
        :source_url => norm_params[:u],

        :texts => { '$all' => [{
          :text => norm_params[:t1],
          :x => norm_params[:t1x],
          :y => norm_params[:t1y],
          :w => norm_params[:t1w],
          :h => norm_params[:t1h],
          }, {
          :text => norm_params[:t2],
          :x => norm_params[:t2x],
          :y => norm_params[:t2y],
          :w => norm_params[:t2w],
          :h => norm_params[:t2h],
          }], '$size' => 2}
        )
        existing
      else
        if same_source = MemeData.find_by_source_url(norm_params[:u])
          source_fs_path = same_source.source_fs_path
        else
          source_img = ImageList::SourceImage.new
          source_img.fetch! norm_params[:u]
          source_img.prepare! settings.source_img_max_side, settings.watermark
          source_fs_path = source_img.cache(norm_params[:u], 'source_cache')
        end

        open(source_fs_path, 'rb') do |source_io|
          t1 = TextPos.new(norm_params[:t1], norm_params[:t1x],
            norm_params[:t1y], norm_params[:t1w], norm_params[:t1h])

          t2 = TextPos.new(norm_params[:t2], norm_params[:t2x],
            norm_params[:t2y], norm_params[:t2w], norm_params[:t2h])

          meme_img = MemeCaptain.meme(source_io, [t1, t2])
          meme_img.extend ImageList::Cache

          # convert non-animated gifs to png
          if meme_img.format == 'GIF' and meme_img.size == 1
            meme_img.format = 'PNG'
          end

          params_s = norm_params.sort.map(&:join).join
          meme_hash = Digest::SHA1.hexdigest(params_s)

          meme_id = nil
          (6..meme_hash.size).each do |len|
            meme_id = "#{meme_hash[0,len]}.#{meme_img.extension}"
            break  unless MemeData.where(:meme_id => meme_id).count > 0
          end

          meme_fs_path = meme_img.cache(params_s, File.join('public', 'meme'))

          meme_img.write(meme_fs_path) {
            self.quality = 100
          }

          meme_data = MemeData.new(
            :meme_id => meme_id,
            :fs_path => meme_fs_path,
            :mime_type => meme_img.mime_type,
            :size => File.size(meme_fs_path),

            :source_url => norm_params[:u],
            :source_fs_path => source_fs_path,

            :texts => [{
              :text => norm_params[:t1],
              :x => norm_params[:t1x],
              :y => norm_params[:t1y],
              :w => norm_params[:t1w],
              :h => norm_params[:t1h],
              }, {
              :text => norm_params[:t2],
              :x => norm_params[:t2x],
              :y => norm_params[:t2y],
              :w => norm_params[:t2w],
              :h => norm_params[:t2h],
            }],

            :request_count => 0,

            :creator_ip => request.ip
            )

          meme_data.save! :safe => true

          meme_data
        end

      end
    end

    get '/g' do
      raise Sinatra::NotFound  if params[:u].to_s.empty?

      begin
        meme_data = gen(params)

        meme_url = url("/#{meme_data.meme_id}")

        [200, { 'Content-Type' => 'application/json' }, {
          'imageUrl' => meme_url,
        }.to_json]
      rescue => error
        [500, { 'Content-Type' => 'text/plain' }, error.to_s]
      end
    end

    def serve_img(meme_data)
      meme_data.requested!

      content_type meme_data.mime_type

      FileBody.new meme_data.fs_path
    end

    get '/i' do
      raise Sinatra::NotFound  if params[:u].to_s.empty?

      serve_img(gen(params))
    end

    get %r{^/([a-f0-9]+\.(?:gif|jpg|png))$} do
      if meme_data = MemeData.find_by_meme_id(params[:captures][0])
        serve_img meme_data
      else
        raise Sinatra::NotFound
      end
    end

    not_found do
      @root_url = url('/')

      erb :'404'
    end

    helpers do
      include Rack::Utils
      alias_method :h, :escape_html
    end

  end

end
