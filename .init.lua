function _G.run_code_block()
	local node = vim.treesitter.get_node({ ignore_injections = false })

	if not node then
		print("No treesitter node found!")
		return
	end

	-- find injected C++ root
	while node and node:type() ~= "translation_unit" do
		node = node:parent()
	end

	if not node then
		print("No translation_unit found!")
		return
	end

	local start_row, start_col, end_row, end_col = node:range()

	local lines = vim.api.nvim_buf_get_text(
		0,
		start_row,
		start_col,
		end_row,
		end_col,
		{}
	)

	local code = table.concat(lines, "\n")

	local temp_file = vim.fn.getcwd() .. "/test.cpp"

	local file = assert(io.open(temp_file, "w"))
	file:write(code)
	file:close()

	vim.cmd("split | set nonu nornu | term ./build_cpp.sh")
end

vim.keymap.set("n", "<leader>r", run_code_block, { silent = true })
