#!/bin/bash

# 指定目录
dir="$(realpath $1)"

# 遍历目录下的所有 .jpg 和 .png 文件
for file in "$dir"/*.{jpg,jpeg,png,webp}
do
  # 检查文件是否存在
  if [ -f "$file" ]
  then
    echo "Processing $file"

    # 使用 mogrify 命令等比例缩放图片，这里以将宽度缩放至 50px 为例，参数应为 50x
    mogrify -resize $2 "$file"
  fi
done

