--[[
   Restore the commands using the 'prepare', 'make' & 'post' branches
   of the recipe
--]]

local conf = dofile  '/etc/bbq.conf' -- load BBQ configuration
local lib  = require 'bbq.lib'


local function getPatchFromUrl (patch, dir)
   local hand

   if not patch.name then
      patch.name = patch.url:gsub('.*/', '') -- basename
   end

   hand = io.open (conf.src..patch.name)
   if not hand then
      lib.exec ('wget -O "%s" "%s"', conf.src..patch.name, patch.url)
      hand = io.open (conf.src..patch.name)
      if not hand then
         hand:close ()
         lib.die ("Can't get patch from %s", patch.url)
      end
   end
   hand:close ()

   lib.exec ('cp %s %s', conf.src..patch.name, dir)
end


local function getPatchFromRecipe (recipe, name, dir)
   local index, hand

   if not recipe.files then
      lib.die ("Can't get file \"%s\" from recipe (no files)", name)
   else
      for i in ipairs (recipe.files) do
         if recipe.files[i].name == name then
            index = i
         end
      end
      if not index then
         lib.die ("Can't get file \"%s\" from recipe (not defined)", name)
      end
   end

   hand = io.open (dir..'temp', 'w')
   hand:write (recipe.files[index].content)

   if recipe.files[index].type then
      if recipe.files[index].type == 'base64' then
         lib.exec ('base64 -d %s > %s; rm %s', dir..'temp', dir..name, dir..'temp')
      else
         lib.die ('Unknown type "%s" for file "%s"', recipe.files[index].type, recipe.files[index].name)
      end
   else
      lib.exec ('mv %s %s', dir..'temp', dir..name)
   end
end


local function makePrepare (recipe, script)
   local s -- script handler
   local p -- 'prepare' branch in recipe
   local patchdir

   if not recipe.prepare then
      return -- no prepare rules
   end

   s = io.open (script, 'w')
   s:write ('prepare_rules() {\n')

   p = recipe.prepare

   if p.patches then
      patchdir = conf.wok .. recipe.name .. '/patches/'
      lib.emptyDir (patchdir)

      s:write ('\n# patches:\n')
      for i, v in ipairs (p.patches) do
         s:write ('# ['..i..']\n')
         if v.url then
            getPatchFromUrl (v, patchdir)
         elseif v.name then
            getPatchFromRecipe (recipe, v.name, patchdir)
         end

         if v.url  then s:write ('url ='.. v.url  .. '\n') end
         if v.name then s:write ('name='.. v.name .. '\n') end
         if v.args then s:write ('args='.. v.args .. '\n') end
         if v.sha1 then s:write ('sha1='.. v.sha1 .. '\n') end
      end
   end

   if p.rules then
      s:write ('\n# rules:\n')
      s:write (p.rules)
      s:write ('\n')
   end

   s:write ('}\n')
   s:close ()
end


local function makeMake (recipe, script)
   local s -- script handler
   local m -- 'make' branch in recipe

   if not recipe.make then
      return -- no make rules
   end

   s = io.open (script, 'w')
   s:write ('make_rules() {\n')

   m = recipe.make

   if m.type == 'gnu' then
      s:write ('# type: gnu\n')
   end

   s:write ('}\n')
   s:close ()
end


local function makePost (recipe, script)
   local s -- script handler
   local p -- 'post' branch in recipe

   if not recipe.post then
      return -- no post rules
   end

   s = io.open (script, 'w')
   s:write ('post_rules() {\n')

   p = recipe.post

   if p.rules then
      s:write ('# rules\n')
   end

   s:write ('}\n')
   s:close ()
end


local function makeTest (recipe, script)
   local s -- script handler
   local t -- 'test' branch in recipe

   if not recipe.test then
      return -- no test rules
   end

   s = io.open (script, 'w')
   s:write ('test_rules() {\n')

   t = recipe.test

   if t.rules then
      s:write ('# rules\n')
   end

   s:write ('}\n')
   s:close ()
end


return {
   makePrepare = makePrepare,
   makeMake    = makeMake,
   makePost    = makePost,
   makeTest    = makeTest
}
