/*
	Copyright (C) 2016 Apple Inc. All Rights Reserved.
	See LICENSE.txt for this sample’s licensing information
	
	Abstract:
	This file contains the ServerConnection class. The ServerConnection class encapsulates and decapsulates a stream of network data in the server side of the SimpleTunnel tunneling protocol.
*/

import Foundation

/// An object representing the server side of a logical flow of TCP network data in the SimpleTunnel tunneling protocol.
class ServerConnection: Connection, StreamDelegate {

	// MARK: Properties

	/// The stream used to read network data from the connection.
    var readStream: InputStream?

	/// The stream used to write network data to the connection.
    var writeStream: OutputStream?

	// MARK: Interface

	/// Open the connection to a host and port.
	func open(host: String, port: Int) -> Bool {
		simpleTunnelLog("Connection \(identifier) connecting to \(host):\(port)")
		
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &readStream, outputStream: &writeStream)

        guard let newReadStream = readStream, let newWriteStream = writeStream else {
			return false
		}

		for stream in [newReadStream, newWriteStream] {
			stream.delegate = self
			stream.open()
            stream.schedule(in: .main, forMode: RunLoopMode.defaultRunLoopMode)
		}

		return true
	}

	// MARK: Connection

	/// Close the connection.
    override func closeConnection(_ direction: TunnelConnectionCloseDirection) {
		super.closeConnection(direction)
		
        if let stream = writeStream, isClosedForWrite && savedData.isEmpty {
			if let error = stream.streamError {
				simpleTunnelLog("Connection \(identifier) write stream error: \(error)")
			}

            stream.remove(from: .main, forMode: RunLoopMode.defaultRunLoopMode)
			stream.close()
			stream.delegate = nil
			writeStream = nil
		}

        if let stream = readStream, isClosedForRead {
			if let error = stream.streamError {
				simpleTunnelLog("Connection \(identifier) read stream error: \(error)")
			}

            stream.remove(from: .main, forMode: RunLoopMode.defaultRunLoopMode)
			stream.close()
			stream.delegate = nil
			readStream = nil
		}
	}

	/// Abort the connection.
    override func abort(_ _, error: Int = 0) {
		super.abort(error)
        closeConnection(allAll)
	}

	/// Stop reading from the connection.
	override func suspend() {
		if let stream = readStream {
            stream.removeFromRunLoop(.main, forMode: RunLoopMode.defaultRunLoopMode)
		}
	}

	/// Start reading from the connection.
	override func resume() {
		if let stream = readStream {
            stream.scheduleInRunLoop(.main(), forMode: NSDefaultRunLoopMode)
		}
	}

	/// Send data over the connection.
	override func sendData(data: NSData) {
		guard let stream = writeStream else { return }
		var written = 0

		if savedData.isEmpty {
            written = writeData(data as Data, toStream: stream, startingAtOffset: 0)

			if written < data.length {
				// We could not write all of the data to the connection. Tell the client to stop reading data for this connection.
                stream.removeFromRunLoop(.main(), forMode: NSDefaultRunLoopMode)
				tunnel?.sendSuspendForConnection(identifier)
			}
		}

		if written < data.length {
            savedData.append(data as Data, offset: written)
		}
	}

	// MARK: NSStreamDelegate

	/// Handle an event on a stream.
    func stream(aStream: Stream, handleEvent eventCode: Stream.Event) {
		switch aStream {

			case writeStream!:
				switch eventCode {
                case [.hasSpaceAvailable]:
						if !savedData.isEmpty {
							guard savedData.writeToStream(writeStream!) else {
                                tunnel?.sendCloseType(allAll, forConnection: identifier)
								abort()
								break
							}

							if savedData.isEmpty {
                                writeStream?.removeFromRunLoop(.main, forMode: RunLoopMode.defaultRunLoopMode)
								if isClosedForWrite {
                                    closeConnection(writeWrite)
								}
								else {
									tunnel?.sendResumeForConnection(identifier)
								}
							}
						}
						else {
							writeStream?.removeFromRunLoop(.mainRunLoop(), forMode: NSDefaultRunLoopMode)
						}

                case [.endEncountered]:
                    tunnel?.sendCloseType(readStream, forConnection: identifier)
                    closeConnection(.Write)

					case [.ErrorOccurred]:
                        tunnel?.sendCloseType(allAll, forConnection: identifier)
						abort()

					default:
						break
				}

			case readStream!:
				switch eventCode {
                case [.hasBytesAvailable]:
						if let stream = readStream {
							while stream.hasBytesAvailable {
                                var readBuffer = [UInt8](repeating: 0, count: 8192)
								let bytesRead = stream.read(&readBuffer, maxLength: readBuffer.count)

								if bytesRead < 0 {
									abort()
									break
								}

								if bytesRead == 0 {
									simpleTunnelLog("\(identifier): got EOF, sending close")
                                    tunnel?.sendCloseType(writeWrite, forConnection: identifier)
                                    closeConnection(.Read)
									break
								}

								let readData = NSData(bytes: readBuffer, length: bytesRead)
                                tunnel?.sendData(readData as Data, forConnection: identifier)
							}
						}

                case [.endEncountered]:
                        tunnel?.sendCloseType(writeWrite, forConnection: identifier)
                        closeConnection(.Read)

                case [.errorOccurred]:
						if let serverTunnel = tunnel as? ServerTunnel {
                            serverTunnel.sendOpenResultForConnection(connectionIdentifier: identifier, resultCode: .Timeout)
                            serverTunnel.sendCloseType(allAll, forConnection: identifier)
							abort()
						}

                case [.openCompleted]:
						if let serverTunnel = tunnel as? ServerTunnel {
                            serverTunnel.sendOpenResultForConnection(connectionIdentifier: identifier, resultCode: .Success)
						}

					default:
						break
				}
			default:
				break
		}
	}
}
