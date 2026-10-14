-- Telling our own keystrokes apart from the user's — no hs.* dependency.
--
-- apps/dictation's chord tap is live for as long as Fn is held, and it fires on
-- a bare Fn+C (cancel the take) or Fn+S (speak the selection). That was fine
-- while nothing typed during a take. Live dictation types the whole time, so
-- every "c" it puts at the cursor used to come straight back through that tap
-- and throw the take away. The code already knew about the round trip — the
-- synthetic ⌘C that Fn+S fires to grab the selection returns as Fn+⌘C — and
-- guarded it by looking for a modifier, which a bare "c" does not carry.
--
-- Two marks survive CGEventPost, and they answer different questions:
--
--   the source pid   set by the system on every event this process posts. It
--                    says "Hammerspoon typed this", which is what the chord tap
--                    needs, and it cannot be forgotten at a call site.
--   the user data    set by us, and read back unchanged. It says WHICH part of
--                    Hammerspoon typed it, so apps/keystroke_typer's output can
--                    be told from apps/tts's ⌘C. An event nobody marked reads 0.
--
-- The pid is the guard. The marker is for anything that needs the finer answer.

local M = {}

-- Arbitrary, non-zero, and ours. Rides on every event keystroke_typer posts.
M.TYPER = 0x48535459   -- "HSTY"

-- Did this process post the event? `pid` is the event's source process id and
-- `self` is ours. A pid we could not read (nil) is treated as foreign: a
-- missing answer must never be read as permission to swallow a real keystroke.
function M.isOurs(pid, self)
  if type(pid) ~= "number" or type(self) ~= "number" or self <= 0 then return false end
  return pid == self
end

-- Did apps/keystroke_typer post it? Narrower than isOurs: the ⌘C that Fn+S
-- fires is ours and is not the typer's.
function M.isTyper(userData)
  return userData == M.TYPER
end

return M
