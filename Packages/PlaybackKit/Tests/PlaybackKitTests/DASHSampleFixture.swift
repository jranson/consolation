//
//  DASHSampleFixture.swift
//  PlaybackKitTests
//
//  A sanitized copy of a real-world test MPD: the structure, attributes and all 270 SegmentTimeline rows as served
//  (873 video and 1,447 audio segments), with the title replaced, the schema location dropped and long elements
//  wrapped. It holds no host; tests resolve it against an example.com URL.
//

enum DASHSampleFixture {
    static let manifestURLString = "https://media.example.com/vod/title/dash.mpd"

    static let mpd = """
    <?xml version="1.0" encoding="utf-8"?>
    <MPD xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xmlns="urn:mpeg:dash:schema:mpd:2011"
      xmlns:xlink="http://www.w3.org/1999/xlink"
      profiles="urn:mpeg:dash:profile:isoff-live:2011"
      type="static"
      mediaPresentationDuration="PT2H25M0.6S"
      maxSegmentDuration="PT6.0S"
      minBufferTime="PT20.0S">
      <ProgramInformation>
        <Title>Sample Presentation</Title>
      </ProgramInformation>
      <ServiceDescription id="0">
      </ServiceDescription>
      <Period id="0" start="PT0.0S">
        <AdaptationSet id="0" contentType="video" startWithSAP="1" segmentAlignment="true"
            bitstreamSwitching="true" frameRate="24000/1001" maxWidth="3832" maxHeight="1600"
            par="479:200">
          <Representation id="0" mimeType="video/mp4" codecs="hvc1" bandwidth="9304845" width="3832"
              height="1600" scanType="unknown" sar="1:1">
            <SegmentTemplate timescale="24000" initialization="init-$RepresentationID$.mp4"
                media="segment-$RepresentationID$-$Number%05d$.m4s" startNumber="1">
              <SegmentTimeline>
                <S t="168" d="240216" />
                <S d="240240" r="2" />
                <S d="150168" />
                <S d="249240" />
                <S d="240240" r="10" />
                <S d="159168" />
                <S d="240240" r="3" />
                <S d="220200" />
                <S d="324336" />
                <S d="240240" r="2" />
                <S d="312312" />
                <S d="316320" />
                <S d="255240" />
                <S d="240240" r="2" />
                <S d="195192" />
                <S d="170184" />
                <S d="240240" r="1" />
                <S d="174168" />
                <S d="240240" r="3" />
                <S d="166176" />
                <S d="240240" />
                <S d="261264" />
                <S d="240240" r="2" />
                <S d="167160" />
                <S d="240240" r="2" />
                <S d="232224" />
                <S d="240240" />
                <S d="230232" />
                <S d="240240" />
                <S d="287280" />
                <S d="265272" />
                <S d="326328" />
                <S d="182184" />
                <S d="331320" />
                <S d="170184" />
                <S d="199200" />
                <S d="152136" />
                <S d="306312" />
                <S d="319320" />
                <S d="240240" r="1" />
                <S d="215208" />
                <S d="149160" />
                <S d="186192" />
                <S d="212208" />
                <S d="165168" />
                <S d="208200" />
                <S d="240240" />
                <S d="362376" />
                <S d="266256" />
                <S d="240240" r="4" />
                <S d="286296" />
                <S d="240240" r="6" />
                <S d="211200" />
                <S d="240240" r="3" />
                <S d="276264" />
                <S d="240240" />
                <S d="331344" />
                <S d="240240" r="2" />
                <S d="239232" />
                <S d="240240" r="21" />
                <S d="202200" />
                <S d="240240" r="7" />
                <S d="285288" />
                <S d="208224" />
                <S d="240240" r="1" />
                <S d="296280" />
                <S d="240240" r="1" />
                <S d="176184" />
                <S d="240240" r="7" />
                <S d="315312" />
                <S d="207216" />
                <S d="240240" r="2" />
                <S d="166152" />
                <S d="202200" />
                <S d="350352" />
                <S d="240240" r="1" />
                <S d="365376" />
                <S d="240240" />
                <S d="158160" />
                <S d="240240" r="7" />
                <S d="155136" />
                <S d="299304" />
                <S d="240240" r="38" />
                <S d="308304" />
                <S d="173184" />
                <S d="168168" />
                <S d="240240" />
                <S d="181176" />
                <S d="240240" r="8" />
                <S d="302304" />
                <S d="247248" />
                <S d="361368" />
                <S d="240240" r="4" />
                <S d="233232" />
                <S d="356352" />
                <S d="240240" r="6" />
                <S d="182184" />
                <S d="240240" r="10" />
                <S d="291288" />
                <S d="240240" r="12" />
                <S d="208200" />
                <S d="209208" />
                <S d="334344" />
                <S d="212208" />
                <S d="381384" />
                <S d="240240" />
                <S d="353352" />
                <S d="240240" r="12" />
                <S d="147144" />
                <S d="179184" />
                <S d="240240" />
                <S d="367368" />
                <S d="240240" r="1" />
                <S d="209208" />
                <S d="214224" />
                <S d="240240" r="1" />
                <S d="150144" />
                <S d="240240" r="2" />
                <S d="356352" />
                <S d="240240" r="7" />
                <S d="197184" />
                <S d="218232" />
                <S d="240240" />
                <S d="199200" />
                <S d="149136" />
                <S d="153168" />
                <S d="285288" />
                <S d="240240" />
                <S d="165168" />
                <S d="219216" />
                <S d="259248" />
                <S d="287280" />
                <S d="237240" />
                <S d="209208" />
                <S d="147144" />
                <S d="365376" />
                <S d="373368" />
                <S d="214224" />
                <S d="240240" r="6" />
                <S d="204192" />
                <S d="240240" r="22" />
                <S d="310320" />
                <S d="240240" r="50" />
                <S d="234240" />
                <S d="240240" r="12" />
                <S d="235224" />
                <S d="240240" r="9" />
                <S d="260256" />
                <S d="240240" r="16" />
                <S d="146160" />
                <S d="240240" r="1" />
                <S d="232224" />
                <S d="240240" r="19" />
                <S d="271272" />
                <S d="240240" r="3" />
                <S d="164160" />
                <S d="240240" r="3" />
                <S d="187200" />
                <S d="240240" r="5" />
                <S d="258240" />
                <S d="240240" r="1" />
                <S d="274272" />
                <S d="240240" />
                <S d="164184" />
                <S d="240240" r="3" />
                <S d="187176" />
                <S d="240240" r="8" />
                <S d="215208" />
                <S d="240240" r="5" />
                <S d="146160" />
                <S d="184176" />
                <S d="240240" r="30" />
                <S d="292296" />
                <S d="240240" r="1" />
                <S d="161160" />
                <S d="278280" />
                <S d="190176" />
                <S d="158160" />
                <S d="240240" r="10" />
                <S d="295296" />
                <S d="240240" r="9" />
                <S d="335352" />
                <S d="240240" r="3" />
                <S d="146136" />
                <S d="240240" r="2" />
                <S d="373368" />
                <S d="189192" />
                <S d="240240" r="6" />
                <S d="229224" />
                <S d="240240" r="1" />
                <S d="159168" />
                <S d="382368" />
                <S d="382392" />
                <S d="240240" r="10" />
                <S d="207216" />
                <S d="263256" />
                <S d="289296" />
                <S d="189192" />
                <S d="345336" />
                <S d="240240" r="10" />
                <S d="282288" />
                <S d="240240" r="11" />
                <S d="307296" />
                <S d="240240" r="7" />
                <S d="263256" />
                <S d="219240" />
                <S d="177168" />
                <S d="281280" />
                <S d="240240" r="11" />
                <S d="146136" />
                <S d="240240" r="1" />
                <S d="163176" />
                <S d="295296" />
                <S d="215208" />
                <S d="152160" />
                <S d="282288" />
                <S d="304296" />
                <S d="240240" r="1" />
                <S d="208200" />
                <S d="240240" r="17" />
                <S d="363360" />
                <S d="166176" />
                <S d="240240" r="1" />
                <S d="166152" />
                <S d="280296" />
                <S d="226224" />
                <S d="240240" r="5" />
                <S d="230232" />
                <S d="312312" />
                <S d="240240" r="28" />
                <S d="279264" />
                <S d="240240" r="5" />
                <S d="191208" />
                <S d="240240" />
                <S d="262248" />
                <S d="359376" />
                <S d="240240" r="20" />
                <S d="375360" />
                <S d="146160" />
                <S d="240240" />
                <S d="227208" />
                <S d="238248" />
                <S d="366360" />
                <S d="321336" />
                <S d="240240" r="4" />
                <S d="205200" />
                <S d="240240" r="2" />
                <S d="209208" />
                <S d="383376" />
                <S d="240240" />
                <S d="258264" />
                <S d="208200" />
                <S d="240240" r="2" />
                <S d="201216" />
                <S d="240240" r="5" />
                <S d="239232" />
                <S d="160152" />
                <S d="160176" />
                <S d="160152" r="1" />
                <S d="160176" />
                <S d="160152" r="1" />
                <S d="160176" />
                <S d="160152" r="1" />
                <S d="160176" />
                <S d="160152" r="1" />
                <S d="240240" r="46" />
                <S d="5016" />
              </SegmentTimeline>
            </SegmentTemplate>
          </Representation>
        </AdaptationSet>
        <AdaptationSet id="1" contentType="audio" startWithSAP="1" segmentAlignment="true"
            bitstreamSwitching="true" lang="eng">
          <Representation id="1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="384000"
              audioSamplingRate="48000">
            <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011"
                value="6" />
            <SegmentTemplate timescale="48000" initialization="init-$RepresentationID$.mp4"
                media="segment-$RepresentationID$-$Number%05d$.m4s" startNumber="1">
              <SegmentTimeline>
                <S t="0" d="288080" />
                <S d="288768" r="1444" />
                <S d="73216" />
              </SegmentTimeline>
            </SegmentTemplate>
          </Representation>
        </AdaptationSet>
      </Period>
    </MPD>
    """
}
