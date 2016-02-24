require 'mini_magick'
require 'nokogiri'


module Hydra
  module Derivatives
    class Jpeg2kImageNli < Jpeg2kImage

      def process
        image = MiniMagick::Image.read(source_file.content)
        colorspace = image['%[colorspace]'].downcase == 'gray' ? 'gray' : 'color'
        size = image.size
        depth_per_channel = image['%[depth]']
        bit_depth = get_bit_depth(colorspace, size, image.width, image.height, depth_per_channel)
        directives.each do |name, args|
          long_dim = self.class.long_dim(image)
          # Could set file_path to the actually location in the ingested nfs mount,
          # to avoid the write to /tmp
          file_path = self.class.tmp_file('.tif')
          image.write file_path
          recipe = calculate_nli_recipe(args, colorspace, long_dim, size, bit_depth )
          output_file_name = args[:datastream] || output_file_id(name)
          encode_file(output_file_name, recipe, file_path: file_path)
          File.unlink(file_path) unless file_path.nil?
        end
      end

      protected
      def calculate_nli_recipe(args, colorspace, long_dim, size, bit_depth)
        levels_arg = args.fetch(:levels, Hydra::Derivatives::Jpeg2kImage.level_count_for_size(long_dim))
        layer_count = args.fetch(:layers, 8)
        target_compression_ratio = args.fetch(:compression, 10)
        min_output_size_megabytes = args.fetch(:min_output_size, 3)
        compression_ratio = final_compression_ratio(size, target_compression_ratio, min_output_size_megabytes)
        rates_arg = bit_depth.to_f/compression_ratio
        jp2_space_arg = colorspace == 'gray' ? 'sLUM' : 'sRGB'

        %Q{-rate #{rates_arg}
          -jp2_space #{jp2_space_arg}
          -num_threads 4
          -no_weights
          Clayers=#{layer_count}
          Clevels=#{levels_arg}
          "Cprecincts={256,256},{256,256},{256,256},{128,128},{128,128},{64,64},{64,64},{32,32},{16,16}"
          "Cblk={64,64}"
          Cuse_sop=yes
          Corder=RPCL
          ORGgen_plt=yes
          ORGtparts=R
        }.gsub(/\s+/, " ").strip
      end

      def final_compression_ratio(size, target_compression_ratio, min_output_size_megabytes)
        size = size.to_f
        target_compression_ratio = target_compression_ratio.to_f
        min_output_size_bytes = min_output_size_megabytes.to_f * 1048576

        if (size / target_compression_ratio < min_output_size_bytes)
          # Find the compression ratio necessary to ensure the minimum output size
          target_compression_ratio = (size/min_output_size_bytes).round
        end

        return target_compression_ratio
      end

      def get_bit_depth(colorspace, size, width, height, depth_per_channel)
        # This function checks that the image filesize corresponds to number of channels
        # implied by the color space reported by ImageMagick. This is necessary because ImageMagick
        # bases its colorspace value on the actual colours in the image rather than
        # the channel mode (e.g. Greyscale, RGB), with the result that a file which is Greyscale but
        # saved as RGB in Gimp/Photoshop is identified by ImageMagick as Greyscale although its filesize
        # reflects the RGB mode
        if colorspace == "gray"
          predicted_approx_byte_size = width.to_i * height.to_i * (depth_per_channel.to_i/8)
          if  predicted_approx_byte_size * 2 < size
            return 24 * (depth_per_channel.to_i/8)
          else
            return 8 * (depth_per_channel.to_i/8)
          end
        else
          return 24 * (depth_per_channel.to_i/8)
        end
      end

    end
  end
end

