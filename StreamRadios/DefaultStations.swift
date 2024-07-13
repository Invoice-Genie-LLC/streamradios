//
//  DefaultStations.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/5/24.
//

import Foundation
import SwiftUI

struct DefaultStations {
    
    // Albania
    static func addDefaultStationsForAlbania(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("tv.balkanweb.com:8081/news24/livestream/playlist.m3u8", "Radio News 24", "http://tv.balkanweb.com:8081/news24/livestream/playlist.m3u8"),
            ("streaming.ihost.al", "Beatfm.al", "http://streaming.ihost.al:8010"),
            ("eu8.fastcast4u.com/proxy/chillradio?mp=/1", "Chill Radio", "https://eu8.fastcast4u.com/proxy/chillradio?mp=/1"),
            ("cp1.sednastream.com/proxy/clubfm", "Club FM Radio", "https://cp1.sednastream.com/proxy/clubfm?mp=/stream"),
            ("cp1.sednastream.com/proxy/cityradio", "City Radio", "https://cp1.sednastream.com/proxy/cityradio?mp=%2Fstream"),
            ("84.20.83.24:88/broadwavehigh.?src=1", "Radio Kontakt", "http://84.20.83.24:88/broadwavehigh.mp3?src=1"),
            ("klanradio.tvklan.al/live/klanmusicradio1", "Klan Radio", "https://klanradio.tvklan.al/live/klanmusicradio1/playlist.m3u8"),
            ("live.topgold.al/topgold", "Top Gold Radio", "https://live.topgold.al/topgold"),
            ("live.top-media.al/mmr", "My Music Radio", "https://live.top-media.al/mmr"),
            ("radio.oranews.tv", "OraNews", "https://radio.oranews.tv:8443/stream"),
            ("cp1.sednastream.com/proxy/radioone94", "Radio One", "https://cp1.sednastream.com/proxy/radioone94?mp=%2Fstream"),
            ("radioemigranti.com:8000/radio128k", "Radio Emigranti", "http://radioemigranti.com:8000/radio128k"),
            ("185.221.253.173", "Radio Emanuel", "http://185.221.253.173:7800"),
            ("cp1.sednastream.com/proxy/radioshqip", "Radio Shqip", "https://cp1.sednastream.com/proxy/radioshqip?mp=%2F%3Bstream.mp3"),
            ("79.106.48.2:8000/radiotirana1", "Radio Tirana 1", "http://79.106.48.2:8000/radiotirana1"),
            ("79.106.48.2:8000/radiotirana2", "Radio Tirana 2", "http://79.106.48.2:8000/radiotirana2"),
            ("79.106.48.2:8000/radiotiranaklasik1", "Radio Tirana Classic", "http://79.106.48.2:8000/radiotiranaklasik1"),
            ("79.106.48.2:8000/radiotiranafemije", "Radio Tirana Femije", "http://79.106.48.2:8000/radiotiranafemije"),
            ("stream.radiojar.com/sx7zrht0pg0uv", "Play Radio 91.1 FM", "http://stream.radiojar.com/sx7zrht0pg0uv"),
            ("dreamsiteradiocp2.com:8028/stream", "Radio Maria", "http://dreamsiteradiocp2.com:8028/stream"),
            ("cp1.sednastream.com/proxy/radio7albania?mp=/live", "Radio 7 Albania", "https://cp1.sednastream.com/proxy/radio7albania?mp=/live"),
            ("radio.albcast.pro/listen/radio_4plus", "Radio 4 Plus", "https://radio.albcast.pro/listen/radio_4plus/radio.mp3"),
            ("radionos.radioca.st/;?1720844152510", "Radio Nostalgjia", "https://radionos.radioca.st/;?1720844152510"),
            ("stream.iradio.pro/proxy/radiojehona", "Radio Jehona 107.6 FM", "https://stream.iradio.pro/proxy/radiojehona?mp=/1"),
            ("https://play.radioking.io/radiodashuria1", "Radio Dashuria", "https://play.radioking.io/radiodashuria1/523790"),
            ("stream.radiolushnja.al/listen/radio_lushnja", "Radio Lushnja", "https://stream.radiolushnja.al/listen/radio_lushnja/radio.mp3"),
            ("cp1.sednastream.com/proxy/alporadio/stream", "Alpo Radio 94.1 MHZ", "https://cp1.sednastream.com/proxy/alporadio/stream"),



            ("live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            ("radioeurostar.al:9000/stream", "Eurostar Radio", "http://radioeurostar.al:9000/stream"),
            ("live.tiranajazzradio.com:8000/stream", "Tirana Jazz Radio", "https://live.tiranajazzradio.com:8443/stream"),
        ]

        let existingStations = Set(viewModel.stations.filter { $0.country == "Albania" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Albania");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
 
    // Angola
    static func addDefaultStationsForAngola(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("radios.vpn.sapo.pt/AO/radio5.", "RNA Rádio 5", "http://radios.vpn.sapo.pt/AO/radio5.mp3"),
            ("radios.vpn.sapo.pt/AO/radio10.", "Radio Mais 99.1", "http://radios.vpn.sapo.pt/AO/radio10.mp3"),
            ("radios.vpn.sapo.pt/AO/radio14.", "LAC Antena Comercial", "http://radios.vpn.sapo.pt/AO/radio14.mp3"),
            ("radios.vpn.sapo.pt/AO/radio1.", "Radio Escola 88.5 FM", "http://radios.vpn.sapo.pt/AO/radio1.mp3"),
            ("hts03.kshost.com.br:9126/stream.nsv", "Kuia Bue FM", "http://hts03.kshost.com.br:9126/;stream.nsv"),
            ("radios.vpn.sapo.pt/AO/radio4.", "Radio Romantica", "https://radios.vpn.sapo.pt/AO/radio4.mp3"),
            ("canli.arabeskinmerkezi.com/9180/stream", "Angola FM", "https://canli.arabeskinmerkezi.com/9180/stream"),
            ("08.stmip.net:10028/", "Ebnézer Rádio", "http://08.stmip.net:10028/;;"),
            ("centova87.instainternet.com/proxy/mfm?mp=/stream", "Radio MFM Angola", "https://centova87.instainternet.com/proxy/mfm?mp=/stream"),
            ("radios.vpn.sapo.pt/AO/radio12.", "Radio N'Gola Yetu", "https://radios.vpn.sapo.pt/AO/radio12.mp3"),
            ("stream.zeno.fm/gsndh1xvczetv", "Radio Fe", "http://stream.zeno.fm/gsndh1xvczetv"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XHPSFMAAC.", "EXA FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XHPSFMAAC.aac"),
            ("strm112.1.fm/acountry_mobile_", "Absolute Country", "http://strm112.1.fm/acountry_mobile_mp3"),
            ("stream1.dimusic.club:11496/live?type=.", "DIMusic Club Angola", "http://stream1.dimusic.club:11496/live?type=.aac"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Angola" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Angola");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }

    // Australia
    static func addDefaultStationsForAustralia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("abc.net.au/res/streaming/audionews_radio.pls", "ABC News Radio", "http://www.abc.net.au/res/streaming/audio/mp3/news_radio.pls"),
            ("cc.net2streams.com:8565/kissfm.", "Kiss FM 87.6", "http://cc.net2streams.com:8565/kissfm.mp3"),
            ("abc.net.au/res/streaming/audioradio_national.pls", "ABC Radio National", "http://www.abc.net.au/res/streaming/audio/aac/radio_national.pls"),
            ("live-radio01.mediahubaustralia.com/CTRW", "ABC Country", "http://live-radio01.mediahubaustralia.com/CTRW/mp3/;*.mp3"),
            ("theproganrockmachine.out.airtime.pro/theproganrockmachine_b", "The Prog Rock Machine", "https://theproganrockmachine.out.airtime.pro/theproganrockmachine_b"),
            ("live-radio01.mediahubaustralia.com/JAZW", "ABC Jazz", "http://live-radio01.mediahubaustralia.com/JAZW/aac/"),
            ("ais-arn.streamguys1.com/au_004_icy", "Gold 104.3", "https://ais-arn.streamguys1.com/au_004_icy"),
            ("live-radio01.mediahubaustralia.com/3LRW", "ABC 774 Melbourne", "http://live-radio01.mediahubaustralia.com/3LRW/aac/"),
            ("live-radio02.mediahubaustralia.com/GSDW", "ABC Grandstand", "http://live-radio02.mediahubaustralia.com/GSDW/aac/;"),
            ("live-radio01.mediahubaustralia.com/2FMW", "ABC Classic FM", "http://live-radio01.mediahubaustralia.com/2FMW/mp3/;*.mp3"),
            ("live-radio01.mediahubaustralia.com/2LRW", "ABC 702 Sydney", "http://live-radio01.mediahubaustralia.com/2LRW/aac/"),
            ("23203.live.streamtheworld.com/T_RAD_HITS_S01AAC.", "Totally Radio Hits", "https://23203.live.streamtheworld.com/T_RAD_HITS_S01AAC.aac"),
            ("23153.live.streamtheworld.com/SMOOTHRELAX_SYD.", "Smooth Relax", "https://23153.live.streamtheworld.com/SMOOTHRELAX_SYD.mp3"),
            ("streaming.radiostreamlive.com/radioitalianmusic_devices", "Radio Italian Music", "https://streaming.radiostreamlive.com/radioitalianmusic_devices"),
            ("radio886.at/streams/88.6_Hard_Rock/", "88.6 Hard Rock", "http://radio886.at/streams/88.6_Hard_Rock/mp3"),
            ("2mfm.org.au:8000/live", "2M FM 92.1 FM", "http://www.2mfm.org.au:8000/live"),
            ("live-radio01.mediahubaustralia.com/2TJWstream.nsv", "ABC Triple J", "http://www.abc.net.au/res/streaming/audio/aac/triplej.pls"),
            ("streaming.novaentertainment.com.au/nova1069", "Nova 106.9 FM", "http://streaming.novaentertainment.com.au/nova1069"),
            ("sbs-ice.streamguys1.com/sbschill", "SBS Chill", "http://sbs-ice.streamguys1.com/sbschill"),
            ("live-radio01.mediahubaustralia.com/FM2W", "ABC Classic 2", "http://live-radio01.mediahubaustralia.com/FM2W/aac/"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/SMOOTH953_AAC48.?src=neweb", "Smooth FM 95.3", "http://playerservices.streamtheworld.com/api/livestream-redirect/SMOOTH953_AAC48.aac?src=neweb"),
            ("live-radio01.mediahubaustralia.com/4LRW", "ABC 612 Brisbane", "http://live-radio01.mediahubaustralia.com/4LRW/aac/"),
            ("23033.live.streamtheworld.com/T_RAD_90S_S01AAC.", "Totally Radio 90s", "https://23033.live.streamtheworld.com/T_RAD_90S_S01AAC.aac"),
            ("c3.radioboss.fm:8018/stream.m3u", "DiscoRhythm", "http://c3.radioboss.fm:8018/stream.m3u"),
            ("live-radio01.mediahubaustralia.com/6LRW", "ABC 720 Perth", "http://live-radio01.mediahubaustralia.com/6LRW/aac/"),
            ("ais-arn.streamguys1.com/au_007_icy", "KIIS 106.5", "https://ais-arn.streamguys1.com/au_007_icy"),
            ("21423.live.streamtheworld.com/NOVA_SKYNEWSAAC.", "Sky News Australia", "https://21423.live.streamtheworld.com/NOVA_SKYNEWSAAC.aac"),
            ("live-radio01.mediahubaustralia.com/GSDW", "ABC Sport", "http://live-radio01.mediahubaustralia.com/GSDW/mp3/;"),
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Australia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Australia")
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }

    // Argentina
    static func addDefaultStationsForArgentina(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("21933.live.streamtheworld.com/LA_RED_AM910AAC.", "Radio La Red", "https://21933.live.streamtheworld.com/LA_RED_AM910AAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/RIVADAVIA.", "Radio Rivadavia", "https://playerservices.streamtheworld.com/api/livestream-redirect/RIVADAVIA.mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/ROCKANDPOPAAC.", "Rock And Pop FM 95.9", "https://playerservices.streamtheworld.com/api/livestream-redirect/ROCKANDPOPAAC.aac"),
            ("streaming.latina101.com.ar:9000/Repetidoras", "Radio Latina FM 101.1", "http://streaming.latina101.com.ar:9000/Repetidoras"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/BLUE_FM_100_7AAC.", "Blue FM 100.7", "https://playerservices.streamtheworld.com/api/livestream-redirect/BLUE_FM_100_7AAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/FM999_56.", "La 100 - 99.9 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/FM999_56.mp3"),
            ("server1.stweb.tv/rcvos/live/playlist.m3u8", "Radio Con Vos 89.9", "https://server1.stweb.tv/rcvos/live/playlist.m3u8"),
            ("sa..icecast.magma.edge-access.net:7200/sc_rad38", "Radio Nacional Folklorica", "http://sa.mp3.icecast.magma.edge-access.net:7200/sc_rad38"),
            ("ipanel.instream.audio/8004/stream", "El Destape Radio", "https://ipanel.instream.audio/8004/stream"),
            ("ice1.edge-apps.net/urbana.audio", "Urbana Play 104.3", "https://ice1.edge-apps.net/urbana.audio"),
            ("radio10.stweb.tv/radio10/live/playlist.m3u8", "Radio 10 Argentina", "https://radio10.stweb.tv/radio10/live/playlist.m3u8"),
            ("turadioenvivo.com:8430/stream", "Feeling 91.9 FM", "http://turadioenvivo.com:8430/stream"),
            ("sa..icecast.magma.edge-access.net:7200/sc_rad39", "Radio Nacional Rock 93.7", "http://sa.mp3.icecast.magma.edge-access.net:7200/sc_rad39"),
            ("sa..icecast.magma.edge-access.net:7200/sc_rad1", "Radio Nacional AM 870", "http://sa.mp3.icecast.magma.edge-access.net:7200/sc_rad1"),
            ("198.204.234.10:8580/stream", "Radio Recuerdos 106.7", "http://198.204.234.10:8580/stream"),
            ("streaming1.locucionar.com/proxy/fmcumbiambera?mp=/stream", "Fm Cumbiambera", "https://streaming1.locucionar.com/proxy/fmcumbiambera?mp=/stream"),
            ("vale.stweb.tv:1935/vale/live/playlist.m3u8", "Vale 97.1", "http://vale.stweb.tv:1935/vale/live/playlist.m3u8"),
            ("albireo.shoutca.st:9740/stream", "The Musical Box Radio", "http://albireo.shoutca.st:9740/stream"),
            ("ipanel.instream.audio:7000/stream", "AM 530 Somos", "https://ipanel.instream.audio:7000/stream"),
            ("mdstrm.com/audio/5d9d019112cbbb45d6a50960/live.m3u8", "FutuRock", "https://mdstrm.com/audio/5d9d019112cbbb45d6a50960/live.m3u8"),
            ("vmf.edge-apps.net/playlist/urbana.m3u8/play.m3u8", "Urbana Play 104.3", "https://vmf.edge-apps.net/playlist/urbana.m3u8/play.m3u8"),
            ("unlimited2-ar.dps.live/cnn-aricecast.audio", "CNN AM 950", "http://unlimited2-ar.dps.live/cnn-ar/aac/icecast.audio"),
            ("27033.live.streamtheworld.com/AM790_56AAC.", "Radio Mitre AM 790", "https://27033.live.streamtheworld.com/AM790_56AAC.aac"),
            ("server.ohradio.com.ar/9344/stream", "Radio La Luna AM", "https://server.ohradio.com.ar/9344/stream"),
            ("stream4.suenas.net/pobrejohnny", "Pobre Johnny", "https://stream4.suenas.net/pobrejohnny"),
            ("sa..icecast.magma.edge-access.net:7200/sc_rad37", "Nacional Clásica fm 96.7", "http://sa.mp3.icecast.magma.edge-access.net:7200/sc_rad37"),

                     
            

        ]
        let existingStations = Set(viewModel.stations.filter { $0.country == "Argentina" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Argentina");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Bangladesh
    static func addDefaultStationsForBangladesh(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("128.199.184.111:12496/stream", "Jago FM 94.4", "http://128.199.184.111:12496/stream"),
            ("str.radiocapital.fm:8000/stream", "Capital FM 94.8", "http://str.radiocapital.fm:8000/stream"),
            ("stream.zenolive.com/f0bfdk2w34zuv", "Radio Foorti 88.0FM", "http://119.148.23.88:1021/"),
            ("radiopadmabd.radioca.st:9109/radiopadma", "Radio Padma 99.2 FM", "http://radiopadmabd.radioca.st:9109/radiopadma"),
            ("stream-23.zeno.fm/umq9q5uuva5tv?zs=Ems7uMMkR8qN8_L1cIhemg", "Radio Shadhin", "https://stream-23.zeno.fm/umq9q5uuva5tv?zs=Ems7uMMkR8qN8_L1cIhemg"),
            ("66.45.232.131:9994/", "AL-QURAN BANGLA", "http://66.45.232.131:9994/"),
            ("stream.zeno.fm/gpgkgp9mp18uv.", "Radio Ullash", "http://stream.zeno.fm/gpgkgp9mp18uv.mp3"),
            ("stream.zeno.fm/spqbxkqxdf9uv", "Uttorbango Betar", "http://stream.zeno.fm/spqbxkqxdf9uv"),
            ("listen.radioking.com/radio/1743/stream/125", "A2Z RADIO", "https://listen.radioking.com/radio/1743/stream/125"),
            ("s3.myradiostream.com:14498/listen.", "Peoples Radio 91.6 FM", "https://s3.myradiostream.com:14498/listen.mp3"),
            ("audio.streamcast.xyz/listen/radiogoongoon/radio.", "Radio GoonGoon", "https://audio.streamcast.xyz/listen/radiogoongoon/radio.mp3"),
            ("stream.zeno.fm/xuin6ocdc2juv", "Radio Vivid Voice", "https://stream.zeno.fm/xuin6ocdc2juv"),
            ("as1.digitalsynapsebd.com/proxy/bbdkka/stream", "Bangladesh Betar Dhaka", "https://as1.digitalsynapsebd.com/proxy/bbdkka/stream"),
            ("stream.spicefmbd.com/stream.m3u8", "96.4 Spice FM", "https://stream.spicefmbd.com/stream.m3u8"),
            ("stream1.dimusic.club:11496/live?type=.", "DIMusic Club Bangladesh", "http://stream1.dimusic.club:11496/live?type=.aac"),
            ("stream-150.zeno.fm/8wv4d8g4344tv", "Radio Today FM 89.6", "http://stream-150.zeno.fm/8wv4d8g4344tv"),
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Bangladesh" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Bangladesh");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }

    // Bolivia
    static func addDefaultStationsForBolivia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("stream.zeno.fm/pnwpbyfambruv", "Radio Panamericana", "http://stream.zeno.fm/pnwpbyfambruv"),
            ("emiteradio.com/proxy/cumbia90s?mp=/stream", "Radio Cumbia 90s", "https://emiteradio.com/proxy/cumbia90s?mp=/stream"),
            ("radios.istbolivia.com:9976/", "Clásica 100.3 Cochabamba", "http://radios.istbolivia.com:9976/;"),
            ("streamingenbolivia.com/8006/stream", "ATB Radio", "https://streamingenbolivia.com/8006/stream"),
            ("streaming2.locucionar.com:9149/stream", "Radio Monumental Bolivia", "http://streaming2.locucionar.com:9149/stream"),
            ("cloudstream2032.conectarhosting.com:7311/", "Radio Gigante Bolivia", "https://cloudstream2032.conectarhosting.com:7311/;"),
            ("streamingenbolivia.com/8002/stream", "Radio Ciudad", "http://streamingenbolivia.com/8002/stream"),
            ("stream.consultoradas.com:10942/stream", "Stereo 97", "https://stream.consultoradas.com:10942/stream"),
            ("stream.consultoradas.com/8194/stream", "Radio Melodia", "https://stream.consultoradas.com/8194/stream"),
            ("161.35.0.33:8370/radio", "Radio Estelar 92.5 FM", "http://161.35.0.33:8370/radio"),
            ("emiteradio.com/proxy/uyuni?mp=/stream", "Radio Folklorica Uyuni", "https://emiteradio.com/proxy/uyuni?mp=/stream"),
            ("radios.istbolivia.com:9304/stream", "Radio Guadalupe", "http://radios.istbolivia.com:9304/stream"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/DISNEY_BOL_SCAAC.?dist=web-radiodisney", "Radio Disney - La Paz FM 102.7", "https://playerservices.streamtheworld.com/api/livestream-redirect/DISNEY_BOL_SCAAC.aac?dist=web-radiodisney"),
            ("dreamsiteradiocp4.com:8022/stream", "Radio Maria", "http://dreamsiteradiocp4.com:8022/stream"),
            ("eu2.serviaudio.com:23128/stream", "Radio Kantuta Digital", "http://eu2.serviaudio.com:23128/stream"),
            ("stream.zeno.fm/7yetzvv8sm0uv", "Coral FM 96.7 La del Sabor", "https://stream.zeno.fm/7yetzvv8sm0uv"),
            ("conectperu.com/8396/stream", "Radio Deseo", "https://conectperu.com/8396/stream"),
            ("cast6.asurahosting.com/proxy/irfradio/stream", "Radio Chacaltaya", "https://cast6.asurahosting.com/proxy/irfradio/stream"),
            ("stream.zeno.fm/du0x9skxum0uv", "Radio Aymara", "http://stream.zeno.fm/du0x9skxum0uv"),
            ("stream.zeno.fm/cb4zhgss538uv", "Big Radio Bolivia", "http://stream.zeno.fm/cb4zhgss538uv"),
            ("spanel.gcomstreaming.com/8018/stream", "Fm La Paz 96.7", "https://spanel.gcomstreaming.com/8018/stream"),
            ("usa14.fastcast4u.com/proxy/gfloresc?mp=/1", "Radio Fides Cochabamba", "https://usa14.fastcast4u.com/proxy/gfloresc?mp=/1"),
            ("stream.zeno.fm/z73xx5qm8rhvv", "Radio Calacoto", "https://stream.zeno.fm/z73xx5qm8rhvv"),
            ("rponline.presidencia.gob.bo/stream", "Radio Illimani", "https://rponline.presidencia.gob.bo/stream"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Bolivia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Bolivia");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }

    /*
    // Brazil
    static func addDefaultStationsForBrazil(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("3live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Brazil" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Brazil");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Bulgaria
    static func addDefaultStationsForBulgaria(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("4live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Bulgaria" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Bulgaria");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Canada
    static func addDefaultStationsForCanada(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("5live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Canada" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Canada");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Costa Rica
    static func addDefaultStationsForCostaRica(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("6live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Costa Rica" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Costa Rica");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Czech Republic
    static func addDefaultStationsForCzechRepublic(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("7live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Czech Republic" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Czech Republic");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // France
    static func addDefaultStationsForFrance(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("8live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "France" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "France");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Germany
    static func addDefaultStationsForGermany(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("9live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Germany" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Germany");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Greece
    static func addDefaultStationsForGreece(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("10live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Greece" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Greece");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Haiti
    static func addDefaultStationsForHaiti(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("11live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Haiti" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Haiti");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Hungary
    static func addDefaultStationsForHungary(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("12live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Hungary" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Hungary");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // India
    static func addDefaultStationsForIndia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("13live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "India" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "India");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Indonesia
    static func addDefaultStationsForIndonesia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("14live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Indonesia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Indonesia");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Italy
    static func addDefaultStationsForItaly(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("15live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Italy" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Italy");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Japan
    static func addDefaultStationsForJapan(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("16live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Japan" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Japan");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
     // Kosovo
     static func addDefaultStationsForKosovo(to viewModel: RadioStationViewModel) {
         let defaultStations = [
            ("radio.itprishtina.com/aradio", "A Radio 89.4 FM", "https://radio.itprishtina.com/aradio"),
            ("cfm.albaservers.com:8010/", "Capital 92.1 FM", "http://cfm.albaservers.com:8010/"),
             ("s4.radio.co/sd1d1904dc/listen.m3u", "Klan Kosova FM", "http://s4.radio.co/sd1d1904dc/listen.m3u"),
             ("studio28.radiolize.com/radio/8100/radio.", "Kolektiv Radio", "https://studio28.radiolize.com/radio/8100/radio.mp3"),
             ("fm.radiokfor.com:8080/", "Radio K4 Shqip", "http://fm.radiokfor.com:8080/;"),
             ("quasar.shoutca.st:8018/", "Radio Kosova e Lire", "http://quasar.shoutca.st:8018/"),
             ("radio.1dhe1.com:8090/listen.pls", "Zëri i Shtimes", "http://radio.1dhe1.com:8090/listen.pls"),
             ("dreamsiteradiocp2.com:8124/stream", "Radio Maria", "http://dreamsiteradiocp2.com:8124/stream"),
             ("s6.voscast.com:8824/stream.", "Radio Dukagjini", "http://s6.voscast.com:8824/;stream.mp3"),
             ("cast2.my-control-panel.com/proxy/radiopl1/stream", "Radio Plus Kosova", "https://cast2.my-control-panel.com/proxy/radiopl1/stream"),
             ("82.114.72.2:8088/.", "RTK Kosova 1", "http://82.114.72.2:8088/;.mp3"),
             ("82.114.72.2:8098/stream.", "RTK Kosova 2", "http://82.114.72.2:8098/;stream.mp3"),
             ("stream.glamradio.fm:8443/glamradio", "Glam Radio", "https://stream.glamradio.fm:8443/glamradio"),
         ]

         let existingStations = Set(viewModel.stations.filter { $0.country == "Kosovo" }.map { $0.id })
         let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
         
         var newStations = [RadioStation]()
         
         for station in missingStations {
             let iconData = viewModel.loadImageData(named: station.1)
             let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Kosovo");
             viewModel.stations.append(newStation)
             newStations.append(newStation)
         }
     }
     
    // Macedonia
    static func addDefaultStationsForMacedonia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("17live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Macedonia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Macedonia");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Malaysia
    static func addDefaultStationsForMalaysia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("18live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Malaysia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Malaysia");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Mexico
    static func addDefaultStationsForMexico(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("19live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Mexico" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Mexico");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Montenegro
    static func addDefaultStationsForMontenegro(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("20live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Montenegro" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Montenegro");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Netherlands
    static func addDefaultStationsForNetherlands(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("21live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Netherlands" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Netherlands");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // New Zealand
    static func addDefaultStationsForNewZealand(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("221live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "New Zealand" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "New Zealand");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Peru
    static func addDefaultStationsForPeru(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("231live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Peru" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Peru");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Poland
    static func addDefaultStationsForPoland(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("241live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Poland" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Poland");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Portugal
    static func addDefaultStationsForPortugal(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("251live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Portugal" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Portugal");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Russia
    static func addDefaultStationsForRussia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("261live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Russia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Russia");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Serbia
    static func addDefaultStationsForSerbia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("271live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Serbia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Serbia");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Slovakia
    static func addDefaultStationsForSlovakia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("281live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Slovakia" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Slovakia");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // South Africa
    static func addDefaultStationsForSouthAfrica(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("291live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "South Africa" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "South Africa");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Spain
    static func addDefaultStationsForSpain(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("301live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Spain" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Spain");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Sweden
    static func addDefaultStationsForSweden(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("311live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Sweden" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Sweden");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Switzerland
    static func addDefaultStationsForSwitzerland(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("321live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Switzerland" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Switzerland");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Tanzania
    static func addDefaultStationsForTanzania(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("331live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Tanzania" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Tanzania");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Turkey
    static func addDefaultStationsForTurkey(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("341live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Turkey" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Turkey");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // UK
    static func addDefaultStationsForUK(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("351live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "UK" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "UK");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // USA
    static func addDefaultStationsForUSA(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("361live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "USA" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "USA");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Zimbabwe
    static func addDefaultStationsForZimbabwe(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("371live.top-media.al/tar", "Top Albania Radio", "https://live.top-media.al/tar"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Zimbabwe" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Zimbabwe");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Unknown Region
    static func addDefaultStationsForUnknownRegion(to viewModel: RadioStationViewModel) {
        let defaultStations: [(id: String, name: String, url: String)] = [
                // No default stations for Unknown Region
            ]
           
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Unknown Region" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Unknown Region");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
     */

    @StateObject private var viewModel = RadioStationViewModel()
    static func addAllDefaults(to viewModel: RadioStationViewModel) {
        
        addDefaultStationsForAlbania(to: viewModel)
        addDefaultStationsForAlbania(to: viewModel)
        addDefaultStationsForAngola(to: viewModel)
        addDefaultStationsForArgentina(to: viewModel)
        addDefaultStationsForAustralia(to: viewModel)
        addDefaultStationsForBangladesh(to: viewModel)
        addDefaultStationsForBolivia(to: viewModel)
        /*
        addDefaultStationsForBrazil(to: viewModel)
        addDefaultStationsForBulgaria(to: viewModel)
        addDefaultStationsForCanada(to: viewModel)
        addDefaultStationsForCostaRica(to: viewModel)
        addDefaultStationsForCzechRepublic(to: viewModel)
        addDefaultStationsForFrance(to: viewModel)
        addDefaultStationsForGermany(to: viewModel)
        addDefaultStationsForGreece(to: viewModel)
        addDefaultStationsForHaiti(to: viewModel)
        addDefaultStationsForHungary(to: viewModel)
        addDefaultStationsForIndia(to: viewModel)
        addDefaultStationsForIndonesia(to: viewModel)
        addDefaultStationsForItaly(to: viewModel)
        addDefaultStationsForJapan(to: viewModel)
         addDefaultStationsForKosovo(to: viewModel)
        addDefaultStationsForMacedonia(to: viewModel)
        addDefaultStationsForMalaysia(to: viewModel)
        addDefaultStationsForMexico(to: viewModel)
        addDefaultStationsForMontenegro(to: viewModel)
        addDefaultStationsForNetherlands(to: viewModel)
        addDefaultStationsForNewZealand(to: viewModel)
        addDefaultStationsForPeru(to: viewModel)
        addDefaultStationsForPoland(to: viewModel)
        addDefaultStationsForPortugal(to: viewModel)
        addDefaultStationsForRussia(to: viewModel)
        addDefaultStationsForSerbia(to: viewModel)
        addDefaultStationsForSlovakia(to: viewModel)
        addDefaultStationsForSouthAfrica(to: viewModel)
        addDefaultStationsForSpain(to: viewModel)
        addDefaultStationsForSweden(to: viewModel)
        addDefaultStationsForSwitzerland(to: viewModel)
        addDefaultStationsForTanzania(to: viewModel)
        addDefaultStationsForTurkey(to: viewModel)
        addDefaultStationsForUK(to: viewModel)
        addDefaultStationsForUSA(to: viewModel)
        addDefaultStationsForZimbabwe(to: viewModel)
        addDefaultStationsForUnknownRegion(to: viewModel)
         */
    }
}

