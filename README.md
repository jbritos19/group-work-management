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

John Smith, 1234567, 0981 123 456
Maria Gomez; 2345678
3. Carlos Duarte 3456789 0982 333 444

Excel columns can also be copied directly.

Before importing, the application validates each row and identifies:

New students
Existing students
Invalid entries
Missing IDs
Duplicate IDs
Incomplete names

The import process uses an all-or-nothing approach: if any row is invalid, no records are created.

Security & Privacy

The application was designed with a backend architecture that keeps sensitive student information protected.

Student Privacy

Student ID numbers and phone numbers are only accessible to administrators.

The student-facing application does not expose sensitive personal information.

Database Protection

Database operations are handled through a dedicated backend function instead of exposing direct database access to the public client.

Group Locking

Administrators can lock confirmed groups to prevent unauthorized changes.

Activity Logging

Important student and administrative actions are recorded with timestamps for accountability and troubleshooting.

Concurrent Group Assignment

The system prevents a group from exceeding the maximum of 12 members, even when multiple users attempt to join the last available spot at the same time.

Technical Architecture

The project uses a separated frontend and backend structure.

groups-project/
├── supabase/
│   ├── migrations/
│   └── functions/
│       └── group-app/
│           └── index.ts
│
└── web/
    ├── index.html
    ├── admin.html
    └── config.js
Frontend

The web directory contains the client-facing application:

index.html — Student application
admin.html — Administrative interface
config.js — Frontend configuration
Backend

The backend logic is implemented through a Supabase Edge Function responsible for handling student and administrative operations.

Student operations include:

Enter
Register
Logout
Join group
Create group
Leave group
Update profile

Administrative operations include:

Authentication
Student management
Group management
Group imports
Group locking
Activity logging
Settings management
Database

The application uses Supabase and PostgreSQL as the backend data layer.

The database includes entities for:

Students
Groups
Topics
Group memberships
Activity history

Database access is restricted through backend functions and row-level security policies.

Testing

The second version of the system was tested using a local environment with a replica of the production database structure.

The test suites covered:

Database behavior
HTTP API operations
Student application
Administrative panel
Concurrent group assignment
Group imports
Locked groups
Privacy controls
Migration and rollback behavior

The documented test results include:

69/69 database tests
31/31 API tests
49/49 browser tests
Deployment

The student-facing application is deployed using Netlify.

Production URL:

https://grupostrabajopractico.netlify.app/

The backend is deployed using Supabase Edge Functions.

Project Highlights

This project demonstrates experience in:

Building real-world web applications
Designing systems around real user requirements
Developing student-facing workflows
Building administrative dashboards
Backend API development
PostgreSQL and Supabase integration
Data validation
Access control and privacy
Activity logging
Concurrent operation handling
Production deployment
Future Improvements
User authentication with stronger identity verification
Personalized student dashboards
Real-time group updates
Email or WhatsApp notifications
Advanced analytics
Role-based administrative permissions
Improved mobile experience
Automated deployment pipelines
Author

Juan Manuel Britos Rugilo

Independent Software Developer
Systems Analysis Student

GitHub: https://github.com/jbritos19
