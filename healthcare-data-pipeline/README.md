# Healthcare Data Processing Pipeline

This project is a robust, enterprise-grade healthcare data processing pipeline built with Ballerina. It's designed to receive HL7 messages via the MLLP protocol, process them reliably, and distribute the data to multiple destinations in parallel.

## Features

### 🏥 Healthcare Standards & Interoperability

- **HL7 v2.8 Support**: Processes HL7 observation messages (ORU_R01), parsing them into a structured format for easy handling.
- **Patient Data Extraction**: Extracts patient demographics and observation results from HL7 messages.

### 🔄 Reliable Message Processing

- **Idempotent Processors**: Ensures safe message replay without causing side effects or data duplication.
- **Failure Handling**: Automatically captures failed messages with their context, enabling detailed debugging and analysis.
- **Replay Mechanism**: Provides an intelligent retry system with configurable intervals and a maximum number of attempts.
- **Dead-Letter Queue**: Isolates messages that consistently fail after multiple retries at replay, preventing system degradation.
- **Notification on Failure**: Sends alerts to administrators when messages fail, including detailed error reports.

### 📊 Multi-Destination Delivery

The pipeline delivers processed data to multiple destinations in parallel for optimal throughput.

- **Database**: Stores patient data in a PostgreSQL database for persistence and analysis.
- **File System**: Generates and saves Markdown reports for record-keeping.
- **Analytics Integration**: Forwards real-time data to analytics services for immediate insights.

## Quick Start

### Prerequisites

- Ballerina 2201.12.7 or later
- PostgreSQL database
- RabbitMQ server
- Gmail API credentials
- Healthcare analytics API

### Installation & Setup

1. **Clone the repository:**

      ```bash
      git clone https://github.com/TharmiganK/ballerina-examples.git
      cd healthcare-data-pipeline
      ```

2. **Configure the application:**
   Update the `Config.toml` file with your environment settings, including required Gmail API credentials. You can find information on how to obtain these credentials in [the Gmail API setup guide](https://central.ballerina.io/ballerinax/googleapis.gmail/latest#setup-guide).

   > **Note**: Enable debug logs to observe the message flow and troubleshoot any issues.
   >
   > ```toml
   > [ballerina.log]
   > level = "DEBUG"
   > ```

3. **Start infrastructure services:**

      ```bash
      # Start PostgreSQL
      docker run --name postgres -e POSTGRES_PASSWORD=password -p 5432:5432 -d postgres

      # Start RabbitMQ
      docker run --name rabbitmq -p 5672:5672 -p 15672:15672 -d rabbitmq:3-management
      ```

      You can also run a mock analytics endpoint using Ballerina:

      ```ballerina
      service /analytics on new http:Listener(9090) {
         resource function post patient-data() returns http:Accepted => http:ACCEPTED;
      }
      ```

4. **Create the database schema:**
   Run the following SQL command on your PostgreSQL database to create the patient table.

      ```sql
      CREATE TABLE patient (
         pid VARCHAR(50) PRIMARY KEY,
         firstname VARCHAR(100),
         lastname VARCHAR(100),
         gender VARCHAR(10),
         address VARCHAR(200),
         city VARCHAR(100),
         state VARCHAR(50),
         zip VARCHAR(20),
         ssn VARCHAR(20),
         phone VARCHAR(20),
         birthdate VARCHAR(20),
         attendingdoctor VARCHAR(200),
         admissiontype VARCHAR(50),
         admitsource VARCHAR(50),
         hospitalservice VARCHAR(50),
         referringdoctor VARCHAR(200),
         servicingfacility VARCHAR(100),
         timeofvisit VARCHAR(50)
      );
      ```

5. **Run the application:**

      ```bash
      bal run
      ```

      The TCP server will start on the port specified in your configuration (default: 8888).

## Usage

### Sending HL7 Messages

The application listens for HL7 messages via TCP socket. You can use any TCP client or testing tool to send messages.

A simple TCP client is available as a Docker image: `ktharmi176/simple-tcp-client`. More information can be found on its [Docker Hub page](https://hub.docker.com/r/ktharmi176/simple-tcp-client).

The project also includes sample HL7 messages in the `sample-messages/` directory for testing.

## Troubleshooting

### RabbitMQ Message Stores

The pipeline uses RabbitMQ queues to handle messages and manage failures.

- `health.observations.failure`: Contains messages that failed processing.
- `health.observations.replay`: Contains messages scheduled for automatic retry.
- `health.observations.deadletter`: Stores messages that have failed all retry attempts at replay.

### Manual Intervention

For messages that fail, you can manually intervene using the RabbitMQ management console, available at <http://localhost:15672> (default credentials: guest/guest).

- **Transient Errors**: If the error is temporary (e.g., a service outage), you can simply move all messages from the failure store to the replay store to trigger an automatic retry.
- **Selective Replay**: If you need to fix a specific malformed message, you must manually consume that message from the failure queue, correct its payload, and then publish it to the replay queue.
