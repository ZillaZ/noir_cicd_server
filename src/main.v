module main

import os
import json
import time
import net.http { CommonHeader, Handler, Request, Response, Server }

fn get_config_dir() string {
	config_dir := os.config_dir() or { 
		panic('Unable to retrieve server configuration.\n${err}')
	}
	return "${config_dir}/Noir/Server"
}

fn start_env() {
	config_dir := get_config_dir()
	lines := os.read_lines('${config_dir}/env/default_env') or { return }
	for line in lines {
		slice := line.split('=')
		name := slice[0].trim_space()
		value := slice[1].trim_space()
		os.setenv(name, value, true)
	}
}

struct PipelineCommand {
mut:
	program string
	args    []string
}

struct Payload {
mut:
	commands      []PipelineCommand
	filename      string
	file          []u8
	ignore_errors bool
}

struct Success {
	warnings []string
}

struct UnableToSaveFile {}

struct CommandFailed {
	index  int
	reason string
}

type PayloadExecutionResult = Success | UnableToSaveFile | CommandFailed

fn (mut payload Payload) execute() PayloadExecutionResult {
	payload.filename.trim_space()
	if payload.filename.len > 0 && payload.file.len > 0 {
		os.write_file_array(payload.filename, payload.file) or { return UnableToSaveFile{} }
	}
	mut warnings := ['Ignore errors is set to ${payload.ignore_errors}']
	for i, command in payload.commands {
		command_str := '${command.program} ${command.args.join(' ')}'
		result := os.execute(command_str)
		if result.exit_code != 0 {
			err := 'Exited with code ${result.exit_code}.\nOutput: ${result.output.trim_space()}'
			if payload.ignore_errors {
				warnings << err
				continue
			}
			return CommandFailed{i, err}
		}
	}
	return Success{warnings}
}

struct ServerHandler implements Handler {
	key    string
	silent bool
}

fn (handler ServerHandler) log(message []string) {
	config_dir := get_config_dir()
	log_file_path := '${config_dir}/logs'
	log := message.join('\n')
	os.write_file('${log_file_path}/noir-log-${time.now()}', log) or {
		println('Failed to write log file')
	}
	if handler.silent {
		return
	}
	println(log)
}

fn (mut handler ServerHandler) handle(request Request) Response {
	mut log := ['## NEW REQUEST AT ${time.now()}', 'Processing request ${request.data}']
	mut response := Response{}
	auth := request.header.get(CommonHeader.authorization) or {
		response.status_code = 400
		response.status_msg = 'Bad Request'
		response.body = 'Missing authorization header'
		log << 'Request is missing Authorization header'
		handler.log(log)
		return response
	}
	if auth != 'Bearer ${handler.key}' {
		response.status_code = 402
		response.status_msg = 'Not Authorized'
		response.body = 'Invalid key'
		log << 'Request key is invalid'
		handler.log(log)
		return response
	}
	mut payload := json.decode(Payload, request.data) or {
		response.status_code = 400
		response.status_msg = 'Bad Request'
		response.body = 'Malformed JSON Payload'
		log << 'Malformed JSON Payload'
		handler.log(log)
		return response
	}
	result := payload.execute()
	match result {
		Success {
			cast := result as Success
			response.status_code = 200
			response.status_msg = 'OK'
			log << cast.warnings
			log << 'Request processing finished sucessfully'
		}
		UnableToSaveFile {
			response.status_code = 500
			response.status_msg = 'Internal Server Error'
			response.body = 'Unable to save file'
			log << 'Unable to save file'
		}
		CommandFailed {
			cast := result as CommandFailed
			response.status_code = 500
			response.status_msg = 'Internal Server Error'
			response.body = 'Command Failed. ${result.reason}'
			log << 'Command with index ${cast.index} failed (${payload.commands[cast.index]}): ${cast.reason}'
		}
	}
	handler.log(log)
	return response
}

fn start_server() Server {
	silent := os.args.len > 1 && os.args[1] == 'silent'
	port := os.getenv('SERVER_PORT')
	mut server := Server{}
	server.addr = 'localhost:${port}'
	handler := ServerHandler{os.getenv('PIPELINE_KEY'), silent}
	server.handler = handler
	return server
}

fn main() {
	start_env()
	mut server := start_server()
	server.listen_and_serve()
}
