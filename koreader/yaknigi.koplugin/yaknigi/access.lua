-- What the account's subscriptions say about a book Yandex refuses to open.
local Access = {}

local FOR_BOOKS = { bookmate = true, plus = true, simple_bookmate = true }
-- Music alone gives no books.
local NOT_FOR_BOOKS = { basic_music = true }

local function seconds(value)
    local number = tonumber(value)
    if not number then return nil end
    -- Yandex sends seconds, but a date in milliseconds should not read as far in the future.
    return number > 1e11 and number / 1000 or number
end

--- "active": a subscription for books is running. "none": nothing is running. "unknown": the
-- answer does not say, and the reader is not to be told more than is known.
function Access.verdict(levels, now)
    if type(levels) ~= "table" or type(levels.expiration_dates) ~= "table" then return "unknown" end
    local doubt = false
    for _, entry in ipairs(levels.expiration_dates) do
        local level = type(entry) == "table" and entry.level or nil
        local expires = type(entry) == "table" and seconds(entry.expires_at) or nil
        if type(level) ~= "string" then
            doubt = true
        elseif not NOT_FOR_BOOKS[level] then
            if not expires then
                doubt = true
            elseif expires > now then
                if FOR_BOOKS[level] then return "active" end
                doubt = true -- a level not known yet
            end
        end
    end
    if doubt then return "unknown" end
    if type(levels.active_recurrents) == "table" and #levels.active_recurrents > 0 then return "unknown" end
    return "none"
end

return Access
