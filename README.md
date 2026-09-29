# Practical Work Group Management System

A web application designed to help university students organize and manage practical-work groups in a simple and centralized environment.

The system was built for a group of approximately 120 students working across 14 different topics, with groups of 8 to 12 members.

## Live Demo

https://grupostrabajopractico.netlify.app/

## Overview

Managing practical-work groups manually can become difficult when many students need to choose topics, join groups, create new groups, or change their assignments.

This application provides a centralized workflow that allows students to manage their group participation while giving administrators tools to monitor, organize, and manage the entire process.

## Features

### Student Application

Students can:

- Enter using their ID number
- Register their name and phone number
- Browse the 14 available topics
- View groups and group members
- Join an existing group
- Create a new group
- Leave a group
- Change groups
- View their current topic and group
- Access practical-work requirements

### Group Management

Groups support between 8 and 12 members.

The interface provides visual status indicators:

- 1–7 members: Looking for members
- 8–11 members: In formation
- 12 members: Complete

Groups can also be locked once they are confirmed.

## Administrative Features

The administration system provides tools to manage students and groups.

### Dashboard

Administrators can view:

- Total registered students
- Students without a group
- Complete and incomplete groups
- Statistics by topic

### Student Management

Administrators can:

- Search students by name, ID, or phone
- Filter students
- Move students between groups
- Assign groups
- Remove students from groups
- Update student information
- View activity history
- Delete student records

### Group Management

Administrators can:

- Create empty groups
- Import pre-organized groups
- Lock and unlock groups
- Delete groups
- Filter groups by status

### Activity History

The system records important actions with timestamps, including:

- Students joining groups
- Students changing groups
- Students leaving groups
- Administrative actions

### Export Tools

Administrators can:

- Open or close registration
- Enable or disable group changes
- Export data as CSV
- Copy group lists for WhatsApp

## Import Existing Groups

Administrators can import groups that have already been organized.

The system supports multiple input formats, including:

```text
John Smith, 1234567, 0981 123 456
Maria Gomez; 2345678
3. Carlos Duarte 3456789 0982 333 444
