#!/bin/bash
odin build . -debug -vet -out:os2test
./os2test || rm *.txt

