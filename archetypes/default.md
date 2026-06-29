+++
date = '{{ .Date }}'
draft = true
title = '{{ replace .File.ContentBaseName "-" " " | title }}'
description = '{{ replace .File.ContentBaseName "-" " " | title }}'
summary = '{{ replace .File.ContentBaseName "-" " " | title }}'
categories = []
tags = []
keywords = []
slug = '{{ .File.ContentBaseName }}'
+++
