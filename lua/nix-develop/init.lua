---@mod nix-develop `nix develop` for neovim
---@tag nix-develop.nvim
---@tag :NixDevelop
---@brief [[
---https://github.com/figsoda/nix-develop.nvim
--->
---:NixDevelop
---:NixShell
---:RiffShell
---
---:NixDevelop .#foo
---:NixDevelop --impure
---:NixShell nixpkgs#hello
---:RiffShell --project-dir foo
---<
---@brief ]]

local M = {};

local levels = vim.log.levels;
local loop = vim.uv;

-- workaround for "nvim_echo must not be called in a lua loop callback"
local notify = function(msg, level)
    vim.schedule(function()
        vim.notify(msg, level);
    end);
end;

--->lua
---require("nix-develop").ignored_variables["SHELL"] = false
---<
---@class ignored_variables
M.ignored_variables = {
    BASHOPTS = true,
    HOME = true,
    NIX_BUILD_TOP = true,
    NIX_ENFORCE_PURITY = true,
    NIX_LOG_FD = true,
    NIX_REMOTE = true,
    PPID = true,
    SHELL = true,
    SHELLOPTS = true,
    SSL_CERT_FILE = true,
    TEMP = true,
    TEMPDIR = true,
    TERM = true,
    TMP = true,
    TMPDIR = true,
    TZ = true,
    UID = true,
};

--->lua
---require("nix-develop").separated_variables["LUA_PATH"] = ":"
---<
---@class separated_variables
M.separated_variables = {
    PATH = ':',
    XDG_DATA_DIRS = ':',
    buildInputs = ' ',
    nativeBuildInputs = ' ',
    propagatedBuildInputs = ' ',
};

local function check(cmd, args, code, signal)
    if code ~= 0 then
        table.insert(args, 1, cmd);
        notify(
            string.format(
                '`%s` exited with exit code %d',
                table.concat(args, ' '),
                code
            ),
            levels.WARN
        );
        return true;
    end;

    if signal ~= 0 then
        table.insert(args, 1, cmd);
        notify(
            string.format(
                '`%s` interrupted with signal %d',
                table.concat(args, ' '),
                signal
            ),
            levels.WARN
        );
        return true;
    end;
end;

local function setenv(name, value)
    if M.ignored_variables[name] then
        return;
    end;

    local sep = M.separated_variables[name];
    if sep then
        local path = os.getenv(name);

        if path then
            loop.os_setenv(name, value .. sep .. path);
            return;
        end;
    end;

    loop.os_setenv(name, value);
end;

local function read_stdout(opts)
    loop.read_start(opts.stdout, function(err, chunk)
        if err then
            notify('Error when reading stdout: ' .. err, levels.WARN);
        end;

        if chunk then
            opts.output = opts.output .. chunk;
        end;
    end);
end;

---Enter a development environment
---@param cmd string
---@param args string[]
---@param callback function|nil
---@return nil
---@usage `require("nix-develop").enter_dev_env("nix", {"print-dev-env", "--json"}, callback)`
function M.enter_dev_env(cmd, args, callback)
    notify('entering development environment', levels.INFO);

    local opts = { output = '', stdout = loop.new_pipe() };

    loop.spawn(cmd, {
        args = args,
        stdio = { nil, opts.stdout, nil },
    }, function(code, signal)
        if check(cmd, args, code, signal) then
            return;
        end;

        for name, value in pairs(vim.json.decode(opts.output)['variables']) do
            if value.type == 'exported' then
                setenv(name, value.value);

                if name == 'shellHook' then
                    local stdin = loop.new_pipe();

                    loop.spawn('bash', {
                        stdio = { stdin, nil, nil },
                    }, function(_code, _signal)
                        if _code ~= 0 then
                            notify('shellHook failed with exit code %d', levels.WARN);
                        end;

                        if _signal ~= 0 then
                            notify('shellHook interrupted with signal %d', levels.WARN);
                        end;
                    end);

                    stdin:write(value.value);
                end;
            end;
        end;

        notify('successfully entered development environment', levels.INFO);

        if callback ~= nil then
            vim.schedule(callback);
        end;
    end);

    read_stdout(opts);
end;

---Enter a development environment a la `nix develop`
---@param args string[] Extra arguments to pass to `nix print-dev-env`
---@param callback function|nil
---@return nil
---@usage `require("nix-develop").nix_develop({".#foo", "--impure"}, callback)`
function M.nix_develop(args, callback)
    M.enter_dev_env('nix', {
        'print-dev-env',
        '--extra-experimental-features',
        'nix-command flakes',
        '--json',
        unpack(args),
    }, callback);
end;

---Extend a development environment with a new one
---@param cmd string
---@param args string[]
---@param callback function|nil
---@return nil
---@usage `require("nix-develop").extend_dev_env("nix", {"print-dev-env", "--json"}, callback)`
function M.extend_dev_env(cmd, args, callback)
    notify('extending development environment', levels.INFO);

    local opts = { output = '', stdout = loop.new_pipe() };

    loop.spawn(cmd, {
        args = args,
        stdio = { nil, opts.stdout, nil },
    }, function(code, signal)
        if check(cmd, args, code, signal) then
            return;
        end;

        for name, value in pairs(vim.json.decode(opts.output)['variables']) do
            if value.type == 'exported' then
                if string.find(name, 'uildInputs') ~= nil or string.find(name, 'PATH') ~= nil then
                    setenv(name, value.value);
                end;
            end;
        end;

        notify('successfully extended development environment', levels.INFO);

        if callback ~= nil then
            vim.schedule(callback);
        end;
    end);

    read_stdout(opts);
end;

---Extend a development environment a la `nix develop`
---@param args string[] Extra arguments to pass to `nix print-dev-env`
---@param callback function|nil
---@return nil
---@usage `require("nix-develop").nix_develop_extend({".#foo", "--impure"}, callback)`
function M.nix_develop_extend(args, callback)
    M.extend_dev_env('nix', {
        'print-dev-env',
        '--extra-experimental-features',
        'nix-command flakes',
        '--json',
        unpack(args),
    }, callback);
end;

---Enter a development environment a la `nix shell`
---@param _args string[] Extra arguments to pass to `nix build`
---@param callback function|nil
---@return nil
---@usage `require("nix-develop").nix_shell({"nixpkgs#hello"}, callback)`
function M.nix_shell(_args, callback)
    notify('entering development environment', levels.INFO);

    local args = {
        'build',
        '--extra-experimental-features',
        'nix-command flakes',
        '--print-out-paths',
        '--no-link',
        unpack(_args),
    };
    local opts = { output = '', stdout = loop.new_pipe() };

    loop.spawn('nix', {
        args = args,
        stdio = { nil, opts.stdout, nil },
    }, function(code, signal)
        if check('nix', args, code, signal) then
            return;
        end;

        local path = os.getenv('PATH');
        local outs = vim.split(opts.output, '\n', { trimempty = true });

        while true do
            local out = table.remove(outs, 1);

            if not out then
                break;
            end;

            path = out .. '/bin:' .. path;
            local file = io.open(out .. '/nix-support/propagated-user-env-packages');

            if file then
                for line in file:lines() do
                    table.insert(outs, vim.trim(line));
                end;
            end;
        end;

        if path ~= nil then
            loop.os_setenv('PATH', path);
        end;

        notify('successfully entered development environment', levels.INFO);

        if callback ~= nil then
            vim.schedule(callback);
        end;
    end);

    read_stdout(opts);
end;

---Enter a development environment a la `riff shell`
---@param args string[] Extra arguments to pass to `riff print-dev-env`
---@param callback function|nil
---@return nil
---@usage `require("nix-develop").riff_shell({"--project-dir", "foo"}, callback)`
function M.riff_shell(args, callback)
    M.enter_dev_env('riff', {
        'print-dev-env',
        '--json',
        unpack(args),
    }, callback);
end;

return M;
