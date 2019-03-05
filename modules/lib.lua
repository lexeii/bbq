local conf   = dofile  '/etc/bbq.conf' -- load BBQ configuration
local yaml   = require 'yaml'
local colors = require 'ansicolors'
local path   = require 'pl.path'
local pldir  = require 'pl.dir'

local function msg (text, ...)
   print (string.format (colors (text), ...))
end


local function printf (format, ...)
   return (string.format (format, ...))
end


local function exec (cmd, ...)
   local command = string.format (cmd, ...)
   return os.execute (command)
end


local function die (...)
   msg (...)
   os.exit ()
end


-- Read the recipe, return Lua table containing it

local function readRc (pkg)
   local file, errText = io.open (conf.wok .. pkg .. '/recipe.yaml')
   if not file then
      die ('Recipe for %{red bright}%s%{reset} absent in the wok:\n%s\n', pkg, errText)
   end
   yaml.configure ({load_numeric_scalars = false})
   return yaml.load (file:read ("*a"))
end


-- Make an empty dir, clean it if it not empty

local function emptyDir (d)
   if path.exists (d) then
      assert (pldir.rmtree (d))
   end
   assert (pldir.makepath (d))
end


-- Check if string ends with some pattern

function string:ends (...)
   for _,i in ipairs ({...}) do
      local pattern = i:gsub ('%.', '%%.') .. '$' -- escape dots
      if self:match (pattern) then return true end
   end
   return false
end


-- Extract file to dir

local function extractFile (file, dir, opts)
   local app, cmd

   if file:ends ('.tar.gz', '.tgz',                   -- busybox tar
      '.tar.bz2', '.tar.bz', '.tbz2', '.tbz', 'tb2',
      '.tar.xz', '.txz',
      '.tar.lzma',
      '.tar.Z', '.tar.z', '.taz',
      '.tar') then
      cmd = printf ('tar -xf %s -C %s', file, dir)

   elseif file:ends ('.tlz') then -- both LZMA (.tar.lzma) and Lzip (.tar.lz) pretends for .tlz
      local hand  = io.open (file, 'rb')
      local magic = hand:read (4) -- read 4 bytes
      hand:close ()
      if magic == 'LZIP' then
         app = 'lzip'
         cmd = printf ('lzip -dcq %s | tar -xf - -C %s', file, dir)
      else
         cmd = printf ('tar -xf %s -C %s', file, dir)
      end

   elseif file:ends ('.lz') then
      app = 'lzip'
      if file:ends ('.tar.lz') then
         cmd = printf ('lzip -dcq %s | tar -xf - -C %s', file, dir)
      elseif file:ends ('.cpio.lz') then
         cmd = printf ('cd %s; lzip -dcq %s | cpio -idm --quiet', dir, file)
      else
         cmd = printf ('cd %s; lzip -dcq %s', dir, file)
      end

   elseif file:ends ('.zip', '.xpi') then
      cmd = printf ('unzip -qo %s -d %s', file, dir) -- busybox

   elseif file:ends ('.xz') then -- not .tar.xz
      if file:ends ('.cpio.xz') then
         cmd = printf ('cd %s; unxz -ck %s | cpio -idm --quiet', dir, file)
      else
         cmd = printf ('cd %s; unxz -k %s', dir, file)
      end

   elseif file:ends ('.7z') then
      app = 'p7zip'
      cmd = printf ('cd %s; 7zr x %s', dir, file)

   elseif file:ends ('.rpm') then
      cmd = printf ('cd %s; rpm2cpio %s | cpio -idm --quiet', dir, file)

   elseif file:ends ('.run') then
      cmd = printf ('cd %s; /bin/sh %s %s', dir, file, (opts or ''))

   else
      cmd = printf ('cp %s %s', file, dir)
   end

   if app then print ('install "'..app..'"') end

   emptyDir (dir)
   msg ('%{yellow}'..cmd)
   assert (os.execute (cmd))
end


-- Compress dir to file; used to recompress VCS (Hg, Git, ...) sources,
-- so no rare formats here

local function comressDir (dir, file)
   local cmd

   if file:ends ('.tar.gz', '.tgz') then
      cmd = printf ('tar -czf %s -C %s *', file, dir)

   elseif file:ends ('.tar.bz2', '.tar.bz', '.tbz2', '.tbz', '.tb2') then
      cmd = printf ('tar -cjf %s -C %s *', file, dir)

   elseif file:ends ('.tar.xz', '.txz') then
      cmd = printf ('tar -cJf %s -C %s *', file, dir)

   elseif file:ends ('.tar.lzma', '.tlz') then
      cmd = printf ('tar -caf %s -C %s *', file, dir)

   elseif file:ends ('.tar.Z', '.tar.z', '.taz') then
      cmd = printf ('tar -cZf %s -C %s *', file, dir)

   elseif file:ends ('.tar') then
      cmd = printf ('tar -cf %s -C %s *', file, dir)

   elseif file:ends ('.cpio.gz') then
      cmd = printf ('cd %s; find . | cpio -o -H newc --quiet | gzip -c > %s', dir, file)

   elseif file:ends ('.cpio.bz2', '.cpio.bz') then
      cmd = printf ('cd %s; find . | cpio -o -H newc --quiet | bzip2 -c > %s', dir, file)

   elseif file:ends ('.cpio.xz') then
      cmd = printf ('cd %s; find . | cpio -o -H newc --quiet | xz -qzeT0 > %s', dir, file)

   end

   msg ('%{yellow}'..cmd)
   assert (os.execute (cmd))
end

-- .tar.gz   .tbz   .tar.bz2   .tar.xz   .zip   .tar.lzma   .gem   .tar.lz   .tbz2
-- .deb .rpm .tar   .xz   .gz   .xpi   .bz2   .7z   .cpio



return {
   msg         = msg,
   printf      = printf,
   exec        = exec,
   die         = die,
   readRc      = readRc,
   emptyDir    = emptyDir,
   extractFile = extractFile,
   comressDir  = comressDir
}
