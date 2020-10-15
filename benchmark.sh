#!/bin/bash
luajit -e "mem=require('memory');mem.test_all(bit)" &&
lua5.1 -e "mem=require('memory');mem.test_all(require('bit'))" &&
lua5.3 -e "mem=require('memory');mem.test_all(bit32)" &&

luajit -e "mem=require('memory');mem.benchmark_all(bit)" &&
lua5.1 -e "mem=require('memory');mem.benchmark_all(require('bit'))" &&
lua5.3 -e "mem=require('memory');mem.benchmark_all(bit32)"
