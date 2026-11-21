cd /tmp
xcrun clang arch.m -framework Foundation -framework Metal -o arch 2>&1 | grep error | head
./arch 2>&1 | grep -v "^metal2vulkan" | cut -c1-160 | head -80
