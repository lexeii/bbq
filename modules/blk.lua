--[[
   Working with the blockings list.
   Using:
      blk = require 'blk'
      pkg = 'glibc'

   -- 1) block glibc
      blk.block(pkg)

   -- 2) unblock glibc
      blk.unblock(pkg)

   -- 3) test
      if not blk.blocked(pkg) then
         print "Your backage is unblocked"
      end
--]]

--local pkg = {}

local conf = dofile  '/etc/bbq.conf' -- load BBQ configuration
local lib  = require 'bbq.lib'
local msg  = lib.msg


local function write (blocked)
   local file = io.open (conf.blocked, "w")
   file:write ('return {')
   for i in pairs (blocked) do
      file:write (i .. '=1,')
   end
   file:write ('}\n')
   file:close ()
end


local function block (pkg)
   local b = dofile (conf.blocked)
   if not b[pkg] then
      b[pkg] = true
      write (b)
      msg ('Ok, %s blocked', pkg)
   else
      msg ('No, was %s already blocked', pkg)
   end
end


local function unblock (pkg)
   local b = dofile (conf.blocked)
   if not b[pkg] then
      msg ('No, %s was not blocked', pkg)
   else
      b[pkg] = nil
      write (b)
      msg ('Ok, %s unblocked', pkg)
   end
end


return {
   block   = block,
   unblock = unblock
}
