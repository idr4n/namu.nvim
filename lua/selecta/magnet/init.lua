local M = {}

M.setup = function(opts)
	opts = opts or {}
	require("selecta.magnet.magnet_enhanced").setup(opts)
end

return M
