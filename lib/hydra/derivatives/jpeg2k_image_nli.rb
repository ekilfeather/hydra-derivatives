require 'mini_magick'
require 'nokogiri'


module Hydra
  module Derivatives
    class Jpeg2kImageNli < Jpeg2kImage

      def process
        image = MiniMagick::Image.read(source_datastream.content)
        quality = image['%[channels]'] == 'gray' ? 'gray' : 'color'
        size = image.size
        directives.each do |name, args|
          long_dim = self.class.long_dim(image)
          file_path = self.class.tmp_file('.tif')
          to_srgb = args.fetch(:to_srgb, true)
          if args[:resize] || to_srgb
            preprocess(image, resize: args[:resize], to_srgb: to_srgb, src_quality: quality)
          end
          image.write file_path
          recipe = self.class.kdu_compress_recipe(args, quality, long_dim, size)
          output_datastream_name = args[:datastream] || output_datastream_id(name)
          encode_datastream(output_datastream_name, recipe, file_path: file_path)
          File.unlink(file_path) unless file_path.nil?
        end
      end

      def encode_datastream(dest_dsid, recipe, opts={})
        output_file = self.class.tmp_file('.jp2')
        if opts[:file_path]
          self.class.encode(opts[:file_path], recipe, output_file)
        else
          source_datastream.to_tempfile do |f|
            self.class.encode(f.path, recipe, output_file)
          end
        end
        out_file = File.open(output_file, "rb")
        out_datastream = output_datastream(dest_dsid)
        out_datastream.content = out_file
        out_datastream.mimeType = 'image/jp2'
        #object.add_file_datastream(out_file.read, dsid: dest_dsid, mimeType: 'image/jp2')
        File.unlink(output_file)
      end

      protected
      def preprocess(image, opts={})
        # resize: <geometry>, to_srgb: <bool>, src_quality: 'color'|'gray'
        image.combine_options do |c|
          c.resize(opts[:resize]) if opts[:resize]
          c.profile self.class.srgb_profile_path if opts[:src_quality] == 'color' && opts[:to_srgb]
        end
        image
      end

      def self.encode(path, recipe, output_file)
        kdu_compress = Hydra::Derivatives.kdu_compress_path
        execute "#{kdu_compress} -i #{path} -o #{output_file} #{recipe}"
      end

      def self.srgb_profile_path
        File.join [
          File.expand_path('../../../', __FILE__),
          'color_profiles',
          'sRGB_IEC61966-2-1_no_black_scaling.icc'
        ]
      end

      def self.tmp_file(ext)
        Dir::Tmpname.create(['sufia', ext], Hydra::Derivatives.temp_file_base){}
      end

      def self.long_dim(image)
        [image[:width], image[:height]].max
      end

      def self.kdu_compress_recipe(args, quality, long_dim, size)
        if args[:recipe].is_a? Symbol
          recipe = [args[:recipe].to_s, quality].join('_')
          if Hydra::Derivatives.kdu_compress_recipes.has_key? recipe
            return Hydra::Derivatives.kdu_compress_recipes[recipe]
          else
            Logger.warn "No JP2 recipe for :#{args[:recipe].to_s} ('#{recipe}') found in configuration. Using best guess."
            return Hydra::Derivatives::Jpeg2kImage.calculate_recipe(args,quality,long_dim, size)
          end
        elsif args[:recipe].is_a? String
          return args[:recipe]
        else
          return Hydra::Derivatives::Jpeg2kImage.calculate_recipe(args, quality, long_dim, size)
        end
      end

      def self.calculate_recipe(args, quality, long_dim, size)
        levels_arg = args.fetch(:levels, Hydra::Derivatives::Jpeg2kImage.level_count_for_size(long_dim))
        layer_count = args.fetch(:layers, 8)
        target_compression_ratio = args.fetch(:compression, 10)
        compression_ratio = Hydra::Derivatives::Jpeg2kImage.final_compression_ratio(size, target_compression_ratio)
        rates_arg = Hydra::Derivatives::Jpeg2kImage.layer_rates(layer_count, compression_ratio)

        %Q{-rate #{rates_arg}
          -num_threads 4
          -no_weights
          Clayers=#{layer_count}
          Clevels=7
          "Cprecincts={256,256},{256,256},{256,256},{128,128},{128,128},{64,64},{64,64},{32,32},{16,16}"
          "Cblk={64,64}"
          Cuse_sop=yes
          Corder=RPCL
          ORGgen_plt=yes
          ORGtparts=R
        }.gsub(/\s+/, " ").strip
      end

      def self.final_compression_ratio(size, target_compression_ratio)
        size = size.to_f
        target_compression_ratio = target_compression_ratio.to_f
        min_output_size_megabytes = args.fetch(:min_output_size, 3).to_f
        min_output_size_bytes = min_output_size_megabytes * 1048576

        if (size / target_compression_ratio < min_output_size_bytes)
          # Find the compression ratio necessary to ensure the minimum output size
          compression_ratio = (size/min_output_size_bytes).round
        end
      end

      def self.layer_rates(layer_count,compression_numerator)
        #e.g. if compression_numerator = 10 then compression is 10:1
        rates = []
        cmp = 24.0/compression_numerator
        layer_count.times do
          rates << cmp
          cmp = (cmp/1.618).round(8)
        end
        rates.map(&:to_s ).join(',')
      end

    end
  end
end
