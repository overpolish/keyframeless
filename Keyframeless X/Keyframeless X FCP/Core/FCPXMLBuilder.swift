/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import CoreMedia
import Foundation

enum FCPXMLBuilder {

	static func titleStorylineXML(text: String) -> String {
		"""
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE fcpxml SYSTEM "https://raw.githubusercontent.com/CommandPost/CommandPost/refs/heads/develop/src/extensions/cp/apple/fcpxml/dtd/FCPXMLv1_14.dtd">
		<fcpxml version="1.14">
			<resources>
				<format id="r1" name="FFVideoFormat1080p30" frameDuration="1/30s" width="1920" height="1080" />
				<effect id="r2" name="Basic Title"
					uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti" />
				<media id="r3" name="\(text)">
					<sequence format="r1" duration="300/30s">
						<spine>
							<gap duration="300/30s">
								<spine lane="1">
									<title ref="r2" duration="300/30s" name="\(text)">
										<text>
											<text-style ref="ts1">\(text)</text-style>
										</text>
										<text-style-def id="ts1">
											<text-style font="Helvetica" fontSize="60" fontFace="Regular"
												fontColor="1 1 1 1" alignment="center" />
										</text-style-def>
									</title>
								</spine>
							</gap>
						</spine>
					</sequence>
				</media>
			</resources>
			<ref-clip ref="r3" duration="300/30s" />
		</fcpxml>
		"""
	}

}
