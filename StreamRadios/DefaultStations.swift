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
            ("1live.tiranajazzradio.com:8000/stream", "Tirana Jazz Radio", "https://live.tiranajazzradio.com:8443/stream"),
            
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
            ("stream1.dimusic.club:11496/live?typeAngloa=.", "DIMusic Club Angola", "http://stream1.dimusic.club:11496/live?type=.aac"),
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
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Australia");
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
    
    // Brazil
    static func addDefaultStationsForBrazil(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("antena1.newradio.it/stream?ext=.", "Antena 1 São Paulo", "http://antena1.newradio.it/stream?ext=.mp3"),
            ("hd.matutos.com.br:8008/stream.", "Radio Flashback", "http://hd.matutos.com.br:8008/;stream.mp3"),
            ("audio.97fm.com.br/energia", "Energia 97 FM", "http://audio.97fm.com.br/energia"),
            ("antena1.newradio.it/stream", "Antena 1 FM 94.7", "http://antena1.newradio.it/stream"),
            ("a1rj.streams.com.br:7801/stream", "Antena 1 FM 103.7", "http://a1rj.streams.com.br:7801/stream"),
            ("stream.zeno.fm/aye8zg6wm8quv", "Rádio Saudades", "http://stream.zeno.fm/aye8zg6wm8quv"),
            ("stream.zeno.fm/75r9qc5wm8quv", "Radio Sertanejo", "http://stream.zeno.fm/75r9qc5wm8quv"),
            ("54.38.43.201:8009/stream-128k-BossaNovaBrazil", "Rádio Bossa Nova", "http://54.38.43.201:8009/stream-128kmp3-BossaNovaBrazil"),
            ("stream.zeno.fm/6knukz6wm8quv", "Radio Sertanejo Só Modão", "http://stream.zeno.fm/6knukz6wm8quv"),
            ("streaming12.hstbr.net:8084/live", "Rádio Disco Funk BR", "http://streaming12.hstbr.net:8084/live"),
            ("stream.zeno.fm/n4ad115wm8quv", "Radio HITS 80", "http://stream.zeno.fm/n4ad115wm8quv"),
            ("live.hunter.fm/sertanejo_high", "Hunter FM - SERTANEJO", "https://live.hunter.fm/sertanejo_high"),
            ("servidor28.brlogic.com:8212/live", "Máquina do Tempo", "http://servidor28.brlogic.com:8212/live"),
            ("servidor28.brlogic.com:8032/live", "Máquina do Tempo Brasil", "http://servidor28.brlogic.com:8032/live"),
            ("live.hunter.fm/lofi_high", "Hunter FM - LOFI", "https://live.hunter.fm/lofi_high"),
            ("stream.zeno.fm/ffup286wm8quv", "Radio Pagode Brasil", "http://stream.zeno.fm/ffup286wm8quv"),
            ("a1rj.streams.com.br:7801/sm", "Antena 1 Rio de Janeiro", "http://a1rj.streams.com.br:7801/sm"),
            ("server02.ouvir.radio.br:8050/stream?1609720768800", "Bons Tempos FM", "https://server02.ouvir.radio.br:8050/stream?1609720768800"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/RADIO_89FM_ADP.?dist=site-89fm", "89 A Radio Rock", "https://playerservices.streamtheworld.com/api/livestream-redirect/RADIO_89FM_ADP.aac?dist=site-89fm"),
            ("cast4.audiostream.com.br:8649/", "Radio Grenal", "http://cast4.audiostream.com.br:8649/mp3"),
            ("centova5.transmissaodigital.com:20104/live", "Bossa Jazz Brasil", "https://centova5.transmissaodigital.com:20104/live"),
            ("provisioning.streamtheworld.com/pls/JBFMAAC.pls", "JB FM", "http://provisioning.streamtheworld.com/pls/JBFMAAC.pls"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/SAUDADE_FMAAC.", "Rádio Saudade FM 99.7", "https://playerservices.streamtheworld.com/api/livestream-redirect/SAUDADE_FMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/RADIOCIDADEAAC.", "Rádio Cidade - Rio de Janeiro", "https://playerservices.streamtheworld.com/api/livestream-redirect/RADIOCIDADEAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/RadioBandeirantesAAC.m3u8", "Rádio Bandeirantes - São Paulo", "https://playerservices.streamtheworld.com/api/livestream-redirect/RadioBandeirantesAAC.m3u8"),
            ("servidor32.brlogic.com:8056/live", "Route 66 - Soundtrack", "http://servidor32.brlogic.com:8056/live"),
            ("stream.zeno.fm/8m9n4s5wm8quv", "Radio Gospel Brasil", "http://stream.zeno.fm/8m9n4s5wm8quv"),
            ("servidor39.brlogic.com:8146/live", "Rádio Transamérica Hits", "http://servidor39.brlogic.com:8146/live"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/MIXFM_SAOPAULOAAC.", "Radio Mix FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/MIXFM_SAOPAULOAAC.aac"),
            ("servidor39-3.brlogic.com:8572/live", "Rádio Velho Brasil", "https://servidor39-3.brlogic.com:8572/live"),
            
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
    
    // China
    static func addDefaultStationsForChina(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("ls.qingting.fm/live/3412131.m3u8?bitrate=64", "华语金曲500首", "http://ls.qingting.fm/live/3412131.m3u8?bitrate=64"),
            ("piccpndali.v.myalicdn.com/audio/cctv13_2.m3u8", "CCTV-13新闻伴音", "https://piccpndali.v.myalicdn.com/audio/cctv13_2.m3u8"),
            ("lhttp.qtfm.cn/live/15318317/64k.", "CNR-1 中国之声", "https://lhttp.qtfm.cn/live/15318317/64k.mp3"),
            ("ngcdn002.cnr.cn/live/jjzs/index.m3u8", "CNR-2 经济之声", "http://ngcdn002.cnr.cn/live/jjzs/index.m3u8"),
            ("lhttp.qingting.fm/live/4804/64k.", "怀集音乐之声", "http://lhttp.qingting.fm/live/4804/64k.mp3"),
            ("lhttp.qtfm.cn/live/20500169/64k.", "新闻听天下", "https://lhttp.qtfm.cn/live/20500169/64k.mp3"),
            ("lhttp.qingting.fm/live/15318585/64k.", "民歌悠扬", "https://lhttp.qingting.fm/live/15318585/64k.mp3"),
            ("playtv-live.ifeng.com/live/06OLEEWQKN4_audio.m3u8", "凤凰卫视资讯台", "http://playtv-live.ifeng.com/live/06OLEEWQKN4_audio.m3u8"),
            ("lhttp.qtfm.cn/live/5022308/64k.", "500首华语经典", "https://lhttp.qtfm.cn/live/5022308/64k.mp3"),
            ("playtv-live.ifeng.com/live/06OLEGEGM4G_audio.m3u8", "凤凰卫视中文台", "http://playtv-live.ifeng.com/live/06OLEGEGM4G_audio.m3u8"),
            ("lhttp.qingting.fm/live/5022107/64k.", "动听音乐网络电台", "http://lhttp.qingting.fm/live/5022107/64k.mp3"),
            ("ngcdn014.cnr.cn/live/ylgb/index.m3u8", "CNR-12 故事广播", "http://ngcdn014.cnr.cn/live/ylgb/index.m3u8"),
            ("lhttp.qtfm.cn/live/20500172/64k.", "国际新闻", "https://lhttp.qtfm.cn/live/20500172/64k.mp3"),
            ("zbbf2.ahbztv.com/live/4f3.m3u8", "CNR-1 中国之声", "http://zbbf2.ahbztv.com/live/4f3.m3u8"),
            ("lhttp.qingting.fm/live/20207761/64k.", "80后音悦台", "http://lhttp.qingting.fm/live/20207761/64k.mp3"),
            ("lhttp.qingting.fm/live/4915/64k.", "清晨音乐台", "http://lhttp.qingting.fm/live/4915/64k.mp3"),
            ("stm.rthk.hk/radio1", "RTHK Radio-1", "http://stm.rthk.hk/radio1"),
            ("ngcdn003.cnr.cn/live/yyzs/index.m3u8", "CNR-3 音乐之声", "http://ngcdn003.cnr.cn/live/yyzs/index.m3u8"),
            ("sk.cri.cn/hyhq.m3u8", "CRI中文环球广播·CRI chinese service", "http://sk.cri.cn/hyhq.m3u8"),
            ("sk.cri.cn/905.m3u8", "CRI环球资讯广播", "https://sk.cri.cn/905.m3u8"),
            ("sk.cri.cn/am846.m3u8", "CRI英语资讯广播 China Plus Radio", "http://sk.cri.cn/am846.m3u8"),
            ("live.cgtn.com/200/prog_index.m3u8", "CGTN English", "http://live.cgtn.com/200/prog_index.m3u8"),
            ("piccpndali.v.myalicdn.com/audio/cctv4_2.m3u8", "CCTV-4中文国际伴音", "https://piccpndali.v.myalicdn.com/audio/cctv4_2.m3u8"),
            ("piccpndali.v.myalicdn.com/audio/cctv1_2.m3u8", "CCTV-1综合伴音", "https://piccpndali.v.myalicdn.com/audio/cctv1_2.m3u8"),
            ("ngcdn004.cnr.cn/live/dszs/index.m3u8", "CNR-4 经典音乐广播", "http://ngcdn004.cnr.cn/live/dszs/index.m3u8"),
            ("stream.zeno.fm/689zc32y4x8uv", "雨声轻音乐", "https://stream.zeno.fm/689zc32y4x8uv"),
            ("asiafm.hk:8000/asiahd", "AsiaFM高清音乐台", "http://asiafm.hk:8000/asiahd"),
            ("play-radio-stream3.hndt.com/now/WUBA5hW2/chunklist.m3u8", "天籁之音 - 经典正流行", "http://play-radio-stream3.hndt.com/now/WUBA5hW2/chunklist.m3u8"),
            ("lhttp.qingting.fm/live/270/64k.", "上海新闻广播", "http://lhttp.qingting.fm/live/270/64k.mp3"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "China" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "China");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    
    // Bulgaria
    static func addDefaultStationsForBulgaria(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("149.13.0.81/radio1.ogg", "Radio 1 Bulgaria", "http://149.13.0.81/radio1.ogg"),
            ("149.13.0.80/nrj128", "Energy Radio Bulgaria", "http://149.13.0.80/nrj128"),
            ("stream.bnr.bg:8011/horizont.", "БНР Хоризонт", "http://stream.bnr.bg:8011/horizont.aac"),
            ("stream.radioreklama.bg/bgradio128", "BG Radio", "http://stream.radioreklama.bg/bgradio128"),
            ("stream.metacast.eu/veronika.ogg", "Veronika Radio", "https://23563.live.streamtheworld.com/RADIO_VERONIKAAAC_L_SC?dist=DESKTOP"),
            ("stream.radioreklama.bg/novanews.", "Nova News", "http://stream.radioreklama.bg/novanews.aac"),
            ("stream.metacast.eu/radio1rock.ogg", "Radio 1 Rock", "http://stream.metacast.eu/radio1rock.ogg"),
            ("darikradio.by.host.bg:8000/S2-128", "Darik Radio", "https://darikradio.by.host.bg:8000/S2-128"),
            ("play.global.audio/bgestrada", "BG Estrada", "https://play.global.audio/bgestrada"),
            ("193.108.24.21:8000/fresh", "Fresh Radio Bulgaria", "http://193.108.24.21:8000/fresh"),
            ("rnmediagroup.com:10000/", "Maya Varna", "http://rnmediagroup.com:10000/;"),
            ("stream-bg-01.radiotangra.com:8000/Tangra-high", "Tangra Mega Rock", "http://stream-bg-01.radiotangra.com:8000/Tangra-high"),
            ("25433.live.streamtheworld.com/AVTORADIOAAC_H.?dist=PREDAVATEL", "Avto Radio", "https://25433.live.streamtheworld.com/AVTORADIOAAC_H.aac?dist=PREDAVATEL"),
            ("mpc1.mediacp.eu:8024/", "Радио Пияника", "http://mpc1.mediacp.eu:8024/;"),
            ("stream.bnr.bg:8012/hristo-botev.", "БНР Христо Ботев", "http://stream.bnr.bg:8012/hristo-botev.aac"),
            ("31.13.223.148:8000/city.", "City Bulgaria", "http://31.13.223.148:8000/city.mp3"),
            ("88.80.96.25:8000/", "Ultra Sandanski", "http://88.80.96.25:8000/"),
            ("radio.networx.bg:8000/TrafficRadio", "Traffic Radio Bulgaria", "http://radio.networx.bg:8000/TrafficRadio"),
            ("stream.bnr.bg:8030/radio-sofia.", "BNR Sofia", "http://stream.bnr.bg:8030/radio-sofia.aac"),
            ("cdn.tvoetoradio.net:8000/HD", "Sweet Radio Bulgaria", "http://cdn.tvoetoradio.net:8000/HD"),
            ("bss1.neterra.tv/veselina/veselina.m3u8", "Radio Veselina", "https://bss1.neterra.tv/veselina/veselina.m3u8"),
            ("ultranet.biz/ultrablagoevgrad.m3u", "Ultra Blagoevgrad", "http://www.ultranet.biz/ultrablagoevgrad.m3u"),
            ("darikradio.by.host.bg:8000/Nostalgie", "Дарик Носталджи", "https://darikradio.by.host.bg:8000/Nostalgie"),
            
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
            ("usa17.fastcast4u.com:5508/listen.pls", "ChroniX Radio", "http://usa17.fastcast4u.com:5508/listen.pls"),
            ("maggie.torontocast.com:2020/stream/reggaechillcafe", "REGGAE CHILL CAFE", "https://maggie.torontocast.com:2020/stream/reggaechillcafe"),
            ("streams.calmradio.com:1228/", "Calm Radio - Solo Piano", "http://streams.calmradio.com:1228/"),
            ("provisioning.streamtheworld.com/pls/CFRBAMAAC.pls", "CFRB News/Talk", "http://provisioning.streamtheworld.com/pls/CFRBAMAAC.pls"),
            ("rogers-hls.leanstream.co/rogers/tor680.stream/playlist.m3u8", "680 News Toronto", "https://rogers-hls.leanstream.co/rogers/tor680.stream/playlist.m3u8"),
            ("rcavliveaudio.akamaized.net/hls/live/2006635/P-2QMTL0_MTL/playlist.m3u8", "ICI Radio-Canada", "https://rcavliveaudio.akamaized.net/hls/live/2006635/P-2QMTL0_MTL/playlist.m3u8"),
            ("s2.ssl-stream.com/radio/8180/radio.", "Labgate - Progressive Rock", "https://s2.ssl-stream.com/radio/8180/radio.mp3"),
            ("maggie.torontocast.com:2020/stream/100greatestofthe80s", "100 GREATEST 80'S", "https://maggie.torontocast.com:2020/stream/100greatestofthe80s"),
            ("provisioning.streamtheworld.com/pls/TV_CTV_NEWSAAC.pls", "CTV News Channel", "http://provisioning.streamtheworld.com/pls/TV_CTV_NEWSAAC.pls"),
            ("mediaserv73.live-streams.nl:18058/stream", "Ancient FM", "https://mediaserv73.live-streams.nl:18058/stream"),
            ("maggie.torontocast.com:2020/stream/natureradiorain", "Nature Radio Rain", "https://maggie.torontocast.com:2020/stream/natureradiorain"),
            ("cbcradiolive.akamaized.net/hls/live/2041036/ES_R1ETR/master.m3u8", "CBC Radio 1 Toronto", "https://cbcradiolive.akamaized.net/hls/live/2041036/ES_R1ETR/master.m3u8"),
            ("s-09.wefunkradio.com:81/wefunk64.", "WEFUNK Radio", "http://s-09.wefunkradio.com:81/wefunk64.mp3"),
            ("maggie.torontocast.com:2020/stream/rdmixeurodance90s", "RDMIX EURODANCE 90'S", "https://maggie.torontocast.com:2020/stream/rdmixeurodance90s"),
            ("streams.radiomast.io/radioblues-flac", "Radio BluesFlac", "http://streams.radiomast.io/radioblues-flac"),
            ("icecast-choi.rncm.ca/choi.", "CHOI 98.1 Radio X", "http://icecast-choi.rncm.ca/choi.aac"),
            ("streams.calmradio.com:6828/stream", "Calm Radio - Bach", "http://streams.calmradio.com:6828/stream"),
            ("listen.cinemix.fr/", "Cinemix", "http://listen.cinemix.fr/"),
            ("maggie.torontocast.com:2020/stream/vibrazionirockradio", "70 80 90 Vibrazioni Rock", "https://maggie.torontocast.com:2020/stream/vibrazionirockradio"),
            ("mpc1.mediacp.eu/stream/smoothjazzdeluxe", "Smooth Jazz Deluxe", "https://mpc1.mediacp.eu/stream/smoothjazzdeluxe"),
            ("streams.calmradio.com:3328/stream", "Calm Radio - Baroque", "http://streams.calmradio.com:3328/stream"),
            ("streams.calmradio.com:7328/stream", "Calm Radio - Mozart", "http://streams.calmradio.com:7328/stream"),
            ("live.leanstream.co/CILQFM", "CILQ 107.1 Q107 Toronto", "http://live.leanstream.co/CILQFM"),
            ("puma.streemlion.com:2910/stream", "80's New Wave Radio", "https://puma.streemlion.com:2910/stream"),
            ("s1.streamaudio.de:8000/forest-green", "Forest Green Radio", "http://s1.streamaudio.de:8000/forest-green"),
            ("streams.calmradio.com:4528/stream", "Calm Radio - Violin", "http://streams.calmradio.com:4528/stream"),
            ("listen.radioking.com/radio/10713/stream/224413", "Gritty Rock Radio", "https://listen.radioking.com/radio/10713/stream/224413"),
            ("rcavliveaudio.akamaized.net/hls/live/2006635/P-2QMTL0_MTL/adaptive_192/master.m3u8", "00-Radio Canada Montreal", "https://rcavliveaudio.akamaized.net/hls/live/2006635/P-2QMTL0_MTL/adaptive_192/master.m3u8"),
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
            ("ic.streann.com:8000/disneycostarica", "Radio Disney Costa Rica", "http://ic.streann.com:8000/disneycostarica"),
            ("okradio.rtvhd.net:8130/stream/1", "Ok Radio 105.5 FM", "http://okradio.rtvhd.net:8130/;stream/1"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/BESAME_CR_SC.", "Bésame Costa Rica - 89.9 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/BESAME_CR_SC.mp3"),
            ("provisioning.streamtheworld.com/pls/LOS40_CR.pls", "Los 40 Principales Costa Rica", "http://provisioning.streamtheworld.com/pls/LOS40_CR.pls"),
            ("rtvhd.net:9942/stream/1", "IQ Radio", "http://rtvhd.net:9942/;stream/1"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/LOS40_CRAAC.", "LOS40 Costa Rica - 104.3 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/LOS40_CRAAC.aac"),
            ("sechin.grupocentroserver.com/radio/8060/radio.", "Radio Mil Recuerdos Stereo", "https://sechin.grupocentroserver.com/radio/8060/radio.mp3"),
            ("s5.radio.co/sd515b7b34/listen", "Radio Dos - 99.5 FM", "https://s5.radio.co/sd515b7b34/listen"),
            ("dreamsiteradiocp2.com:8044/stream", "Radio María - 100.7 FM", "http://dreamsiteradiocp2.com:8044/stream"),
            ("s2.radio.co/s83b86382e/listen", "Radio Columbia CR", "https://s2.radio.co/s83b86382e/listen"),
            ("live.turadio.stream:7004/stream", "1047hit", "https://live.turadio.stream:7004/stream;"),
            ("okradio.rtvhd.net:8130/", "Vox FM Costa Rica - 105.5 FM", "http://okradio.rtvhd.net:8130/;"),
            ("usa18.fastcast4u.com/proxy/rmoohhrw?mp=/1", "Urbano 106 - 105.9 FM", "https://usa18.fastcast4u.com/proxy/rmoohhrw?mp=/1"),
            ("streams.y2kwebs.com:9972/", "Radio Sinfonola 90.3FM", "http://streams.y2kwebs.com:9972/"),
            ("68.235.35.243:9008/stream", "Radio Frecuencia Tierra", "http://68.235.35.243:9008/stream"),
            ("stream.zeno.fm/tet7d7sz2yzuv", "Radio Platino", "http://stream.zeno.fm/tet7d7sz2yzuv"),
            ("stream20.usastreams.com/8094/stream", "Planet 107.5", "https://stream20.usastreams.com/8094/stream"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/QTEJA_CRAAC_SC", "La Caliente 90.7 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/QTEJA_CRAAC_SC"),
            ("rtvhd.net:9932/listen.pls", "Radio Omega 105.1 FM", "http://rtvhd.net:9932/listen.pls"),
            ("streams.y2kwebs.com:9310/stream/1/", "104.7 HIT", "http://streams.y2kwebs.com:9310/stream/1/"),
            ("centova.hostingtico.com:8016/stream", "Radio Nova CR", "http://centova.hostingtico.com:8016/stream"),
            ("stream.zeno.fm/ftcx2988uwzuv", "Radio Revolución", "https://stream.zeno.fm/ftcx2988uwzuv"),
            ("stream20.usastreams.com/8090/stream", "Radio Spectro", "https://stream20.usastreams.com/8090/stream"),
            ("ic.streann.com/disneycostarica", "Radio Disney Costa Rica - 101.1 FM", "https://ic.streann.com/disneycostarica"),
            ("18683.live.streamtheworld.com/CRC_959AAC.", "959 Nueve Cinco Nueve", "https://18683.live.streamtheworld.com/CRC_959AAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/CRC_947AAC.?_=819140", "Nueve Cuatro Siete - 94.7 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/CRC_947AAC.aac?_=819140"),
            ("virtualtronics.net/proxy/zetafm?mp=/stream", "Zeta FM 95.1", "https://virtualtronics.net/proxy/zetafm?mp=/stream"),
            ("s1.voscast.com:11392/stream", "Tamarindo Radio", "http://s1.voscast.com:11392/stream"),
            
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
            ("rfe21.akacast.akamaistream.net/7/751/437779/v1/ibb.akacast.akamaistream.net/rfe21", "RFE/RL Radio Farda", "http://rfe21.akacast.akamaistream.net/7/751/437779/v1/ibb.akacast.akamaistream.net/rfe21"),
            ("rfe04.akacast.akamaistream.net/7/509/437762/v1/ibb.akacast.akamaistream.net/rfe04.m3u", "Радио Свобода - Radio Svoboda", "http://rfe04.akacast.akamaistream.net/7/509/437762/v1/ibb.akacast.akamaistream.net/rfe04.m3u"),
            ("icecast2.play.cz:8000/country128", "Country Radio", "http://icecast2.play.cz:8000/country128aac"),
            ("icecast2.play.cz:8000/kiss128", "Kiss 98 FM", "http://icecast2.play.cz:8000/kiss128aac"),
            ("rfe-ingest.akamaized.net/hls/live/2035254/axia04/playlist.m3u8", "Радио Свобода", "https://rfe-ingest.akamaized.net/hls/live/2035254/axia04/playlist.m3u8"),
            ("icecast2.play.cz/radiobeat128.", "Radio Beat", "http://icecast2.play.cz/radiobeat128.mp3"),
            ("icecast8.play.cz/cro1-128.", "ČRo Radiožurnál", "http://icecast8.play.cz/cro1-128.mp3"),
            ("icecast6.play.cz/casrock128.", "Radio Čas Rock", "http://icecast6.play.cz/casrock128.mp3"),
            ("ice.abradio.cz/blanikfm128.", "Rádio Blaník živé", "http://ice.abradio.cz/blanikfm128.mp3"),
            ("stream4.abradio.cz:8000/humor128.", "Radio Humor", "http://mp3stream4.abradio.cz:8000/humor128.mp3"),
            ("icecast8.play.cz/kisshady128.", "Kiss Hady", "http://icecast8.play.cz/kisshady128.mp3"),
            ("icecast6.play.cz/cro2-128.", "ČRo Dvojka", "http://icecast6.play.cz/cro2-128.mp3"),
            ("ice.abradio.cz/blanikcz128.", "Rádio Blaník", "http://ice.abradio.cz/blanikcz128.mp3"),
            ("ice.abradio.cz/hit90128.", "Hitrádio Devadesátka", "http://ice.abradio.cz/hit90128.mp3"),
            ("ice.abradio.cz/orion128.", "HIT Rádio Orion", "http://ice.abradio.cz/orion128.mp3"),
            ("icecast5.play.cz/impuls128.", "Impuls Ráááádio", "http://icecast5.play.cz/impuls128.mp3"),
            ("icecast8.play.cz/freeradio128.", "Free Rádio 107,0 FM Brno", "http://icecast8.play.cz/freeradio128.mp3"),
            ("icecast6.play.cz/cesky-impuls.", "Český Impuls", "http://icecast6.play.cz/cesky-impuls.mp3"),
            ("icecast4.play.cz/kiss128.", "Radio Kiss", "http://icecast4.play.cz/kiss128.mp3"),
            ("ice3.abradio.cz/pohadka128.", "Rádio pohádka", "http://ice3.abradio.cz/pohadka128.mp3"),
            ("ice.abradio.cz/fajn128.", "Fajn Rádio", "http://ice.abradio.cz/fajn128.mp3"),
            ("ice.abradio.cz/oldiesradio128.", "Oldies Rádio", "http://ice.abradio.cz/oldiesradio128.mp3"),
            ("ice.abradio.cz/hit80128.", "Hitrádio Osmdesátka", "http://ice.abradio.cz/hit80128.mp3"),
            ("icecast5.play.cz/cro3-128.", "ČRo Vltava", "http://icecast5.play.cz/cro3-128.mp3"),
            ("ice.abradio.cz/helax128.", "Helax 93,7", "http://ice.abradio.cz/helax128.mp3"),
            ("ice.actve.net/dance-radio320.", "Dance Radio", "http://ice.actve.net/dance-radio320.mp3"),
            ("ice.abradio.cz/metalomanie128.", "Metalománie", "http://ice.abradio.cz/metalomanie128.mp3"),
            ("ice.abradio.cz/hitradiofm128.", "Hitrádio FM", "http://ice.abradio.cz/hitradiofm128.mp3"),
            ("amp.cesnet.cz:8000/cro-plus-256.ogg.m3u", "ČRo Plus", "http://amp.cesnet.cz:8000/cro-plus-256.ogg.m3u"),
            ("ice.actve.net/fm-frekvence1-", "Frekvence 1", "http://ice.actve.net/fm-frekvence1-aac"),
            
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
            ("live02.rfi.fr/rfiafrique-64.", "RFI Afrique", "http://live02.rfi.fr/rfiafrique-64.mp3"),
            ("direct.franceinfo.fr/live/franceinfo-midfi.", "France Info", "http://direct.franceinfo.fr/live/franceinfo-midfi.mp3"),
            ("direct.franceinter.fr/live/franceinter-hifi.", "France Inter", "http://direct.franceinter.fr/live/franceinter-hifi.aac"),
            ("live02.rfi.fr/rfimonde-64.", "RFI Monde", "http://live02.rfi.fr/rfimonde-64.mp3"),
            ("jazzblues.ice.infomaniak.ch/jazzblues-high.", "Jazz Radio Blues", "http://jazzblues.ice.infomaniak.ch/jazzblues-high.mp3"),
            ("audio.bfmtv.com/rmcradio_128.", "RMC FR", "https://audio.bfmtv.com/rmcradio_128.mp3"),
            ("185.52.127.132/fr/30601/_128.?origine=fluxradios", "Nostalgie", "http://185.52.127.132/fr/30601/mp3_128.mp3?origine=fluxradios"),
            ("cdn.nrjaudio.fm/audio1/fr/30001/_128.?origine=fluxradios?1535727639539.", "NRJ", "http://cdn.nrjaudio.fm/audio1/fr/30001/mp3_128.mp3?origine=fluxradios?1535727639539.mp3"),
            ("streaming.radio.rtl.fr/rtl-1-44-128", "RTL", "http://streaming.radio.rtl.fr/rtl-1-44-128"),
            ("icecast.radiofrance.fr/franceculture-hifi.", "France Culture", "http://icecast.radiofrance.fr/franceculture-hifi.aac"),
            ("jazzradio.ice.infomaniak.ch/jazzradio-high.", "Jazz Radio", "http://jazzradio.ice.infomaniak.ch/jazzradio-high.mp3"),
            ("cdn.nrjaudio.fm/audio1/fr/30201/_128.", "Chérie Fm", "http://cdn.nrjaudio.fm/audio1/fr/30201/mp3_128.mp3"),
            ("cdn.nrjaudio.fm/audio1/fr/30401/_64.", "Rire et Chansons", "http://cdn.nrjaudio.fm/audio1/fr/30401/aac_64.mp3"),
            ("icecast.skyrock.net/s/natio__128k", "Skyrock", "http://icecast.skyrock.net/s/natio_mp3_128k"),
            ("icecast.radiofrance.fr/fip-hifi.", "FIP", "http://icecast.radiofrance.fr/fip-hifi.aac"),
            ("streaming.radio.rtl2.fr/rtl2-1-44-128", "RTL2", "http://streaming.radio.rtl2.fr/rtl2-1-44-128"),
            ("radiomeuh.ice.infomaniak.ch/radiomeuh-128.", "Radio Meuh", "http://radiomeuh.ice.infomaniak.ch/radiomeuh-128.mp3"),
            ("stream-eurodance90.fr/radio/8000/128.?1627933323", "EuroDance 90 radio", "https://stream-eurodance90.fr/radio/8000/128.mp3?1627933323"),
            ("radioclassique.ice.infomaniak.ch/radioclassique-high.", "Radio Classique", "http://radioclassique.ice.infomaniak.ch/radioclassique-high.mp3"),
            ("100radio-80.ice.infomaniak.ch/100radio-80-128.", "100% Radio 80", "http://100radio-80.ice.infomaniak.ch/100radio-80-128.mp3"),
            ("novazz.ice.infomaniak.ch/novazz-128.", "Radio Nova", "http://novazz.ice.infomaniak.ch/novazz-128.mp3"),
            ("hd.lagrosseradio.info/lagrosseradio-reggae-192.", "La Grosse Radio Reggae", "http://hd.lagrosseradio.info/lagrosseradio-reggae-192.mp3"),
            ("cdn.nrjaudio.fm/adwz1/fr/30043/_128.?origine=fluxradios", "NRJ Hits", "http://cdn.nrjaudio.fm/adwz1/fr/30043/mp3_128.mp3?origine=fluxradios"),
            ("stream.chantefrance.com/Chante_France", "Chante France", "http://stream.chantefrance.com/Chante_France"),
            ("ice.creacast.com/sudradio", "Sud Radio", "https://ice.creacast.com/sudradio"),
            ("streaming.radio.funradio.fr/fun-1-44-128", "Fun Radio", "http://streaming.radio.funradio.fr/fun-1-44-128"),
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
            ("stream.mangoradio.de/", "MANGORADIO", "http://stream.mangoradio.de/"),
            ("st01.dlf.de/dlf/01/128stream.", "Deutschlandfunk", "http://st01.dlf.de/dlf/01/128/mp3/stream.mp3"),
            ("hirschmilch.de:7001/prog-house.", "Hirschmilch Radio", "https://hirschmilch.de:7001/prog-house.mp3"),
            ("wdr-1live-live.icecast.wdr.de/wdr/1live/live128/stream.", "1LIVE", "http://wdr-1live-live.icecast.wdr.de/wdr/1live/live/mp3/128/stream.mp3"),
            ("channels.webradio.rockantenne.de/heavy-metal", "Rock Antenne - Heavy Metal", "http://mp3channels.webradio.rockantenne.de/heavy-metal"),
            ("streams.80s80s.de/web/-192/streams.80s80s.de/", "80s80s", "http://streams.80s80s.de/web/mp3-192/streams.80s80s.de/"),
            ("stream.sunshine-live.de/90er/-192/stream.sunshine-live.de", "Sunshine Live - Die 90er", "http://stream.sunshine-live.de/90er/mp3-192/stream.sunshine-live.de"),
            ("wdr-wdr5-live.icecast.wdr.de/wdr/wdr5/live128/stream.", "WDR 5", "http://wdr-wdr5-live.icecast.wdr.de/wdr/wdr5/live/mp3/128/stream.mp3"),
            ("channels.webradio.rockantenne.de/rockantenne", "Rock Antenne", "http://mp3channels.webradio.rockantenne.de/rockantenne"),
            ("streams.90s90s.de/pop/-192/streams.90s90s.de/", "90s90s Hits", "http://streams.90s90s.de/pop/mp3-192/streams.90s90s.de/"),
            ("channels.webradio.antenne.de/antenne", "Antenne Bayern", "http://mp3channels.webradio.antenne.de/antenne"),
            ("streams.90s90s.de/hiphop/-192/streams.90s90s.de/", "90s90s HipHop & Rap", "http://streams.90s90s.de/hiphop/mp3-192/streams.90s90s.de/"),
            ("stream.sunshine-live.de/techno/-192/stream.sunshine-live.de/", "Sunshine Live - Techno", "http://stream.sunshine-live.de/techno/mp3-192/stream.sunshine-live.de/"),
            ("lw2..tb-group.fm/tb.", "TechnoBase.FM", "http://lw2.mp3.tb-group.fm/tb.mp3"),
            ("stream.sunshine-live.de/live/-192/stream.sunshine-live.de/", "Sunshine Live", "http://stream.sunshine-live.de/live/mp3-192/stream.sunshine-live.de/"),
            ("listen.trancebase.fm/tunein--hd-pls", "TranceBase.FM - AAC HD 256k", "http://listen.trancebase.fm/tunein-aac-hd-pls"),
            ("liveradio.swr.de/sw282p3/swr3/play.", "SWR3", "https://liveradio.swr.de/sw282p3/swr3/play.mp3"),
            ("channels.webradio.antenne.de/chillout", "Antenne Bayern - Chillout", "http://mp3channels.webradio.antenne.de/chillout"),
            ("radioeins.de/stream", "Radio Eins", "http://radioeins.de/stream"),
            ("st03.dlf.de/dlf/03/128stream.", "Deutschlandfunk Nova", "http://st03.dlf.de/dlf/03/128/mp3/stream.mp3"),
            ("streams.90s90s.de/eurodance/-192/radiode/", "90s90s Dance HQ", "http://streams.90s90s.de/eurodance/mp3-192/radiode/"),
            ("inforadio.de/live.m3u", "Inforadio", "http://www.inforadio.de/live.m3u"),
            ("channels.webradio.rockantenne.de/classic-perlen", "ROCK ANTENNE Classic Perlen", "http://mp3channels.webradio.rockantenne.de/classic-perlen"),
            ("stream.instrumentalhits.de:8060/", "RMNinstrumental", "http://stream.instrumentalhits.de:8060/"),
            ("cdn.nrjaudio.fm/adwz1/de/33015/_128.", "Energy NRJ Dance", "http://cdn.nrjaudio.fm/adwz1/de/33015/mp3_128.mp3"),
            ("0n-classicrock.radionetz.de/0n-classicrock.", "Classic Rock on Radio", "https://0n-classicrock.radionetz.de/0n-classicrock.mp3"),
            ("hirschmilch.de:7001/chillout.", "Hirschmilch Radio Chillout", "https://hirschmilch.de:7001/chillout.mp3"),
            ("streams.br.de/b5aktuell_2.m3u", "B5 aktuell", "http://streams.br.de/b5aktuell_2.m3u"),
            ("ais.rastamusic.com/rastamusic..m3u", "Reggae Radio", "http://ais.rastamusic.com/rastamusic.mp3.m3u"),
            
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
            ("cast3.radiohost.ovh:8352/", "Blues Radio", "http://cast3.radiohost.ovh:8352/"),
            ("netradio.live24.gr/kissfmathens", "Kiss 92.9", "http://netradio.live24.gr/kissfmathens"),
            ("live.radiokiss.gr/kissfm1006hq.", "KISS FM 100.6", "http://live.radiokiss.gr/kissfm1006hq.mp3"),
            ("netradio.live24.gr/realfm", "Real FM 97.8", "http://netradio.live24.gr/realfm"),
            ("cast.streams.ovh:2199/tunein/tranceathena.pls", "Trance Athena", "https://cast.streams.ovh:2199/tunein/tranceathena.pls"),
            ("netradio.live24.gr/skai1003", "Skai 100.3", "http://netradio.live24.gr/skai1003"),
            ("sfera.live24.gr/sfera4132", "Sfera 102.2", "http://sfera.live24.gr/sfera4132"),
            ("netradio.live24.gr/sportfm7712", "Sport FM 94.6", "http://netradio.live24.gr/sportfm7712"),
            ("stream.vanillaradio.com:8012/live", "Vanilla Radio Deep Flawors", "https://stream.vanillaradio.com:8012/live"),
            ("netradio.live24.gr/athinaradio", "Παραπολιτικά FM 90.1", "http://netradio.live24.gr/athinaradio"),
            ("radiostreaming.ert.gr/ert-zeppelin", "Zeppelin 106.7", "https://radiostreaming.ert.gr/ert-zeppelin"),
            ("derti.live24.gr/derty1000", "Derti 98.6", "http://derti.live24.gr/derty1000"),
            ("s3.yesstreaming.net:2199/tunein/offradio.pls", "Off Radio - Athens", "https://s3.yesstreaming.net:2199/tunein/offradio.pls"),
            ("cast.magicstreams.gr:9111/stream", "Psyndora Psytrance", "http://cast.magicstreams.gr:9111/stream"),
            ("netradio.live24.gr/orange9320", "Ellinikos 93.2", "http://netradio.live24.gr/orange9320"),
            ("smooth.vanillaradio.com:8032/live.m3u", "Vanilla Radio Smooth Flavors", "https://smooth.vanillaradio.com:8032/live.m3u"),
            ("netradio.live24.gr/loveradio-1000", "Love Radio 97.5", "http://netradio.live24.gr/loveradio-1000"),
            ("netradio.live24.gr/laikos876", "Laikos FM", "http://netradio.live24.gr/laikos876"),
            ("netradio.live24.gr/galaxy9292", "Galaxy 92", "http://netradio.live24.gr/galaxy9292"),
            ("radiostreaming.ert.gr/ert-deftero", "ERA Deftero Programma", "http://radiostreaming.ert.gr/ert-deftero"),
            ("ice.onestreaming.com/athensparty", "Athens Party", "http://ice.onestreaming.com/athensparty"),
            ("mediaserver.mad.tv/stream", "Mad Radio 106.2", "http://mediaserver.mad.tv/stream"),
            ("eco.onestreaming.com:8222/", "Play radio", "http://eco.onestreaming.com:8222/"),
            ("eu4.fastcast4u.com:5248/stream.", "Stone Radio", "http://eu4.fastcast4u.com:5248/;stream.mp3"),
            ("radiostreaming.ert.gr/ert-kosmos", "ERA Kosmos", "http://radiostreaming.ert.gr/ert-kosmos"),
            ("best.live24.gr/best1222", "Best 92.6", "http://best.live24.gr/best1222"),
            ("radiostreaming.ert.gr/ert-proto", "ERA Proto Programma", "http://radiostreaming.ert.gr/ert-proto"),
            ("air-tunein.radioart.com/fMeditation.", "Radio Art - Meditation", "http://air-tunein.radioart.com/fMeditation.mp3"),
            ("metropolis.live24.gr/metropolis955thess", "Metropolis 95.5", "http://metropolis.live24.gr/metropolis955thess"),
            ("live.radioart.com/fSolo_piano.", "Radio Art - Solo Piano", "http://live.radioart.com/fSolo_piano.mp3"),
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
            ("stream.zeno.fm/hpdayz31vd0uv", "RADIO BBC NEWS HAITI", "http://stream.zeno.fm/hpdayz31vd0uv"),
            ("streaming.live365.com/a15951", "KONPA MIX RADIO!", "http://streaming.live365.com/a15951"),
            ("stream.zeno.fm/wus1q53u30duv", "Radio Mega Haiti", "http://stream.zeno.fm/wus1q53u30duv"),
            ("ctntv.getstreamhosting.com:8026/english", "Love a Child Radio", "https://ctntv.getstreamhosting.com:8026/english"),
            ("zafemradio.com:9934/", "Radio Haiti Tropical", "http://zafemradio.com:9934/"),
            ("stream.zeno.fm/fd9kyc28dchvv", "Radio St Charles FM", "http://stream.zeno.fm/fd9kyc28dchvv"),
            ("stream.zeno.fm/xmyroy1iu80uv", "Radio Vision 2000 90.9 FM", "http://stream.zeno.fm/xmyroy1iu80uv"),
            ("stream.zeno.fm/bdkwbv3rt98uv", "RTVS", "https://stream.zeno.fm/bdkwbv3rt98uv"),
            ("stream.zeno.fm/54k0v7x14neuv", "Caraibes FM", "https://stream.zeno.fm/54k0v7x14neuv"),
            ("ctntv.getstreamhosting.com:8028/creole", "Love a Child FM", "https://ctntv.getstreamhosting.com:8028/creole"),
            ("studio.sitegenial.com/9310/stream", "Intermix 93.1 FM", "https://studio.sitegenial.com/9310/stream"),
            ("stream-152.zeno.fm/28zya4hubwzuv?zs=KHC-EIFRRNCzl-jbVyJyjg", "Radio Jeanvonvon", "https://stream-152.zeno.fm/28zya4hubwzuv?zs=KHC-EIFRRNCzl-jbVyJyjg"),
            ("stream-152.zeno.fm/vm8mgn3eewzuv?zs=HWkYw7B5S2C0W0cAcrdGZQ", "Ananda Marga Haiti", "https://stream-152.zeno.fm/vm8mgn3eewzuv?zs=HWkYw7B5S2C0W0cAcrdGZQ"),
            ("stream.zeno.fm/qhlllaz21cmuv", "Radio Humilite", "https://stream.zeno.fm/qhlllaz21cmuv"),
            ("stream.zeno.fm/xsijfdaz7inuv", " Shelove International Radio", "https://stream.zeno.fm/xsijfdaz7inuv"),
            ("stream.zeno.fm/yoz610evcpltv", "Radio Boursiquot's FM 101.7", "https://stream.zeno.fm/yoz610evcpltv"),
            ("stream.zeno.fm/my1hfddd6nhvv", "Radio Mille Colombes FM", "https://stream.zeno.fm/my1hfddd6nhvv"),
            ("stream.zeno.fm/82q102t62neuv", "Radio Kiskeya", "http://stream.zeno.fm/82q102t62neuv"),
            ("stream.zeno.fm/aparrwtkwyzuv", "Radio Jamesen Show", "http://stream.zeno.fm/aparrwtkwyzuv"),
            ("stream-21.zeno.fm/avr8uenbm1duv?zs=HEEdTMZyQ6uSZRff0P3ubg", "Caraibes FM", "https://stream-21.zeno.fm/avr8uenbm1duv?zs=HEEdTMZyQ6uSZRff0P3ubg"),
            ("a8.asurahosting.com:7530/stream", "Radyo Tipiti", "https://a8.asurahosting.com:7530/stream"),
            ("zafemrtv.net/9934/", "Radio Haiti Tropical", "https://zafemrtv.net/9934/;"),
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
            ("dancewave.online/dance.", "Dance Wave", "https://dancewave.online/dance.mp3"),
            ("retro.dancewave.online/retrodance.", "Dance Wave Retro", "https://retro.dancewave.online/retrodance.mp3"),
            ("stream.klubradio.hu:8080/bpstream", "Klubrádió", "http://stream.klubradio.hu:8080/bpstream"),
            ("mr-stream.mediaconnect.hu/4734/mr1.", "Kossuth Rádió", "http://mr-stream.mediaconnect.hu/4734/mr1.aac"),
            ("icast.connectmedia.hu/5201/live.", "Rádió 1 - Budapest", "http://icast.connectmedia.hu/5201/live.mp3"),
            ("stream.mercyradio.eu/kabare.", "Mercy Rádió - Kabaré", "http://stream.mercyradio.eu/kabare.mp3"),
            ("mr-stream.mediaconnect.hu/4737/mr2.", "Petőfi Rádió", "http://mr-stream.mediaconnect.hu/4737/mr2.aac"),
            ("megadanceradio.hopto.org:8000/livemega.", "MegaDance Rádió", "http://megadanceradio.hopto.org:8000/livemega.mp3"),
            ("stream.infostart.hu/lejatszo/index.html?sid=1", "Inforádió", "http://stream.infostart.hu/lejatszo/index.html?sid=1"),
            ("stream.tilos.hu/tilos", "Tilos Rádió", "http://stream.tilos.hu/tilos"),
            ("92.61.114.159:7812/slagerfm256.", "Sláger FM", "http://92.61.114.159:7812/slagerfm256.mp3"),
            ("oxygenmusic.hu:8443/oxygenthe80shits", "Oxygen The 80s Hits", "https://oxygenmusic.hu:8443/oxygenthe80shits"),
            ("s02.diazol.hu:10052/spweb1.", "Spirit FM", "https://s02.diazol.hu:10052/spweb1.mp3"),
            ("oxygenmusic.hu:8443/oxygenmagyarzene", "Oxygen Magyar Zene", "https://oxygenmusic.hu:8443/oxygenmagyarzene"),
            ("stream.webthings.hu:8000/fm95-x-128.", "Best FM", "http://stream.webthings.hu:8000/fm95-x-128.mp3"),
            ("188.165.11.30:5000/luxfunkradio.", "Luxfunk Radio", "http://188.165.11.30:5000/luxfunkradio.mp3"),
            ("188.165.11.30:5000/luxfunkdance.", "Luxfunk Dance", "http://188.165.11.30:5000/luxfunkdance.mp3"),
            ("adas.poptarisznya.hu:8200/live.", "Poptarisznya", "http://adas.poptarisznya.hu:8200/live.mp3"),
            ("mr-stream.mediaconnect.hu/4747/mr7.", "Dankó Rádió", "http://mr-stream.mediaconnect.hu/4747/mr7.aac"),
            ("188.165.11.30:5000/luxfunkblackmix.", "Luxfunk Blackmix", "http://188.165.11.30:5000/luxfunkblackmix.mp3"),
            ("adas.poptarisznya.hu:8200/oldies.", "Poptarisznya Oldies", "http://adas.poptarisznya.hu:8200/oldies.mp3"),
            ("mr-stream.mediaconnect.hu/4742/mr3hq.", "Bartók Rádió", "http://mr-stream.mediaconnect.hu/4742/mr3hq.mp3"),
            ("icast.connectmedia.hu/5001/live.", "Retro Radio", "https://icast.connectmedia.hu/5001/live.mp3"),
            ("stream1.radio88.hu:8300/stream", "Rádió 88 Retro", "http://stream1.radio88.hu:8300/;stream"),
            ("oxygenmusic.hu:8443/oxygenclassicrock", "Oxygen Classic Rock", "https://oxygenmusic.hu:8443/oxygenclassicrock"),
            ("stream.mercyradio.eu/mulatos.", "Mercy Rádió - Mulatós", "http://stream.mercyradio.eu/mulatos.mp3"),
            ("188.165.11.30:4420/live.", "Magic Disco Radio", "http://188.165.11.30:4420/live.mp3"),
            ("klasszikradio.hu/klasszik.", "Klasszik Rádió 92.1", "http://www.klasszikradio.hu/klasszik.mp3"),
            
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
            ("peridot.streamguys.com:7150/Mirchi", "Radio Mirchi", "http://peridot.streamguys.com:7150/Mirchi"),
            ("stream.zeno.fm/m38h4nmgxs8uv", "Hindi - hits", "http://stream.zeno.fm/m38h4nmgxs8uv"),
            ("192.99.8.192:5032/stream", "Fnf.Fm Hindi", "http://192.99.8.192:5032/;stream"),
            ("stream.zeno.fm/6n6ewddtad0uv", "Bollywood Gaane Purane", "https://stream.zeno.fm/6n6ewddtad0uv"),
            ("stream.zeno.fm/84h97t3ewg0uv", "MY RADIO DJ", "http://stream.zeno.fm/84h97t3ewg0uv"),
            ("94.130.113.214:8000/dubtechno", "Radio Schizoid - Dub Techno", "http://94.130.113.214:8000/dubtechno"),
            ("94.130.113.214:8000/chill", "Radio Schizoid", "http://94.130.113.214:8000/chill"),
            ("stream.radiobollyfm.in:8201/hd?t=1526570335", "Radio BollyFm", "http://stream.radiobollyfm.in:8201/hd?t=1526570335"),
            ("94.130.113.214:8000/prog", "Radio Schizoid", "http://94.130.113.214:8000/prog"),
            ("stream.zeno.fm/n2fd0edh9k8uv", "Goldy Evergreen", "https://stream.zeno.fm/n2fd0edh9k8uv"),
            ("sc-bb.1.fm:8017/", "BIG FM 92.7", "http://sc-bb.1.fm:8017/"),
            ("stream.zenolive.com/4g65yz9gg0quv.", "Hello FM 106.4", "https://stream.zenolive.com/4g65yz9gg0quv.aac"),
            ("millenniumhits.out.airtime.pro:8000/millenniumhits_a", "2B! Radio Sangam Krishna", "http://millenniumhits.out.airtime.pro:8000/millenniumhits_a"),
            ("hoth.alonhosting.com:1100/", "Bollyhitsradio", "http://hoth.alonhosting.com:1100/;"),
            ("radio.garden/api/ara/content/listen/to5IKEqr/channel.?1626611643750", "Radio City Hindi", "http://radio.garden/api/ara/content/listen/to5IKEqr/channel.mp3?1626611643750"),
            ("dard.out.airtime.pro:8000/dard_a", "2B! Radio Sangam Shri Ram", "http://dard.out.airtime.pro:8000/dard_a"),
            ("stream.zeno.fm/8ty8szwpwfeuv.m3u", "Hits Of Bollywood", "http://stream.zeno.fm/8ty8szwpwfeuv.m3u"),
            ("ndtvindiaelemarchana.akamaized.net/hls/live/2003679/ndtvindia/masterp_480p@3.m3u8", "New Delhi India TV", "http://ndtvindiaelemarchana.akamaized.net/hls/live/2003679/ndtvindia/masterp_480p@3.m3u8"),
            ("hot.out.airtime.pro:8000/hot_a", "2B! Radio Sangam Shiva", "http://hot.out.airtime.pro:8000/hot_a"),
            ("s3.radio.co/se787a5a6f/listen", "Radio Mirchi 2", "https://s3.radio.co/se787a5a6f/listen"),
            ("stream.zeno.fm/g95zm67prfhvv.m3u", "Hits Of Lata Mangeshkar", "http://stream.zeno.fm/g95zm67prfhvv.m3u"),
            ("stream-161.zeno.fm/87xam8pf7tzuv?zs=fvTPIM3xTWi1Ik-Z9095aA", "Radio Lata Mangeshkar", "https://stream-161.zeno.fm/87xam8pf7tzuv?zs=fvTPIM3xTWi1Ik-Z9095aA"),
            ("stream.zeno.fm/u7eee0hyzp8uv", "MY CLUB REMIX", "http://stream.zeno.fm/u7eee0hyzp8uv"),
            ("stream.zeno.fm/1k0y9f0cm0quv", "Bollywood Punjabi Radio", "http://stream.zeno.fm/1k0y9f0cm0quv"),
            ("stream.zeno.fm/pg6rqp8ztm0uv.m3u", "Hits Of Kishor Kumar", "http://stream.zeno.fm/pg6rqp8ztm0uv.m3u"),
            ("airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio005/hlspbaudio00564kbps.m3u8", "AIR Fm Gold Delhi", "https://airhlspush.pc.cdn.bitgravity.com/httppush/hlspbaudio005/hlspbaudio00564kbps.m3u8"),
            ("directchannel1.hindihits.top/", "Bollywood ", "http://directchannel1.hindihits.top/"),
            ("ibadat.out.airtime.pro:8000/ibadat_a", "2B! Radio Sangam Devi Maa", "http://ibadat.out.airtime.pro:8000/ibadat_a"),
            ("stream.zeno.fm/0zkr7x8ztm0uv.m3u", "Hits Of Mohammed Rafi", "http://stream.zeno.fm/0zkr7x8ztm0uv.m3u"),
            ("sonic.onlineaudience.co.uk/8114/stream?listening-from-radio-garden=1657427657", "Radio Aashiqanaa", "https://sonic.onlineaudience.co.uk/8114/stream?listening-from-radio-garden=1657427657"),
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
            ("202.147.199.99:8000/stream/1", "RDI 97.1 FM", "http://202.147.199.99:8000/;stream/1"),
            ("live.nagaswarafm.com/nagaswararadio/stream", "NAGASWARA RADIOTEMEN", "https://live.nagaswarafm.com/nagaswararadio/stream"),
            ("45.64.97.82:9940/", "Retjo Buntung 99.4 FM", "http://45.64.97.82:9940/"),
            ("stream.radiojar.com/4ywdgup3bnzuv", "I-Radio Jakarta", "http://stream.radiojar.com/4ywdgup3bnzuv"),
            ("wijayafm.onlivestreaming.net:9880/stream?", "Wijaya FM 103.5 FM", "http://wijayafm.onlivestreaming.net:9880/stream?"),
            ("stream.lokermusik.com/listen/lokermusik/lokermusik", "Loker Musik Indonesia", "https://stream.lokermusik.com/listen/lokermusik/lokermusik"),
            ("streaming.girifm.com:8010/", "Suara Giri 98.4 FM", "http://streaming.girifm.com:8010/"),
            ("live.cnnindonesia.com/livecnn/smil:cnntv.smil/chunklist_w275412545_b384000_sleng.m3u8", "CNN Indonesia TV", "http://live.cnnindonesia.com/livecnn/smil:cnntv.smil/chunklist_w275412545_b384000_sleng.m3u8"),
            ("stream.zeno.fm/pvvz3mrtsf9uv", "MTV Indonesia", "https://stream.zeno.fm/pvvz3mrtsf9uv"),
            ("pu.klikhost.com:8052/", "Suara Muslim Surabaya", "http://pu.klikhost.com:8052/"),
            ("shaddai.onlivestreaming.net:9130/live", "EL SHADDAI FM SOLO", "http://shaddai.onlivestreaming.net:9130/live"),
            ("stream-ssl.arenastreaming.com:8000/jakarta", "Elshinta  Jakarta", "https://stream-ssl.arenastreaming.com:8000/jakarta"),
            ("stream.radiojar.com/7csmg90fuqruv", "Hardrock 87.6 FM Jakarta", "http://stream.radiojar.com/7csmg90fuqruv"),
            ("s3.vinhostmedia.com:1031/", "Oz Radio Bandung", "http://s3.vinhostmedia.com:1031/"),
            ("live.bassfm.id/", "Bass FM 93.2 Salatiga", "http://live.bassfm.id/"),
            ("r5.siar.us:8711/stream", "Radio Kanca Tani ( Konco Tani )", "http://r5.siar.us:8711/stream"),
            ("202.147.199.100:8000/stream.nsv", "V Radio", "http://202.147.199.100:8000/;stream.nsv"),
            ("a8.siar.us/listen/campursari/stream", "89.2 FM Jakarta, Campur sari", "https://a8.siar.us/listen/campursari/stream"),
            ("c5.siar.us/proxy/ssfm/stream", "Suara Surabaya FM", "https://c5.siar.us/proxy/ssfm/stream"),
            ("maestro.skyline.net.id:10925/radio.maestro", "Maestro FM Bandung", "http://maestro.skyline.net.id:10925/radio.maestro"),
            ("stream.radiojar.com/rrqf78p3bnzuv.", "TraxFM Jakarta", "https://stream.radiojar.com/rrqf78p3bnzuv.mp3"),
            ("202.147.199.99:8000/", "Radio Dangdut 97.1 FM", "http://202.147.199.99:8000/;"),
            ("stream.zeno.fm/f1b625au2bruv", "Dangdut Lawas", "https://stream.zeno.fm/f1b625au2bruv"),
            ("live.cnnindonesia.com/livecnn/smil:cnntv/chunklist.m3u8", "CNN Indonesia", "https://live.cnnindonesia.com/livecnn/smil:cnntv/chunklist.m3u8"),
            ("u.klikhost.net:8000/gracealone", "Grace Alone Ministry", "http://u.klikhost.net:8000/gracealone"),
            ("sundaradio.com/live/sundaradio", "Sunda Radio", "https://sundaradio.com/live/sundaradio"),
            ("202.147.199.101:8000/stream.nsv", "Sindo Trijaya 104.6 FM", "http://202.147.199.101:8000/;stream.nsv"),
            ("suaragratiafm.japanserver.info:8959/", "Suara Gratia Cirebon", "http://suaragratiafm.japanserver.info:8959/"),
            ("65.108.120.179:8660/stream", "Sonora 92.0 FM", "http://65.108.120.179:8660/stream"),
            ("stream-node0.rri.co.id/streaming/14/9014/kbrn.", "RRI Pro 3 KBRN", "https://stream-node0.rri.co.id/streaming/14/9014/kbrn.mp3"),
            
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
            ("icestreaming.rai.it/1.", "Rai Radio 1", "http://icestreaming.rai.it/1.mp3"),
            ("icecast.unitedradio.it/Radio105.", "Radio 105 Network", "http://icecast.unitedradio.it/Radio105.mp3"),
            ("icy.unitedradio.it/VirginRockClassics.", "Virgin Radio Classic Rock", "http://icy.unitedradio.it/VirginRockClassics.mp3"),
            ("onair11.xdevel.com:8134/stream.", "Radio Stereocittà", "http://onair11.xdevel.com:8134/;stream.mp3"),
            ("icestreaming.rai.it/2.", "Rai Radio 2", "http://icestreaming.rai.it/2.mp3"),
            ("shoutcast2.radio24.it:8000/", "Radio 24", "http://shoutcast2.radio24.it:8000/;"),
            ("icestreaming.rai.it/3.", "Rai Radio 3", "http://icestreaming.rai.it/3.mp3"),
            ("icecast.unitedradio.it/RMC.", "RMC Radio Monte Carlo", "http://icecast.unitedradio.it/RMC.mp3"),
            ("icecast.unitedradio.it/Virgin.", "Virgin Radio Italia", "http://icecast.unitedradio.it/Virgin.mp3"),
            ("icy.unitedradio.it/105Dance90.", "Radio 105 - Dance 90", "http://icy.unitedradio.it/105Dance90.mp3"),
            ("str01.fluidstream.net:7020/stream.", "Radio 80", "http://str01.fluidstream.net:7020/;stream.mp3"),
            ("77.241.4.100:8020/", "Radio Studio Più - HQ", "http://77.241.4.100:8020/;"),
            ("trsw.inmystream.info:8068/stream.", "Tele Radio Stereo", "http://trsw.inmystream.info:8068/;stream.mp3"),
            ("icy.unitedradio.it/VirginRock70.", "Virgin Radio Rock '70", "http://icy.unitedradio.it/VirginRock70.mp3"),
            ("nr8.newradio.it:19574/stream", "70 80 Hits HQ", "https://nr8.newradio.it:19574/stream"),
            ("centova.wlservices.org/proxy/pufepstm?mp=/stream", "Milano Lounge Radio", "https://centova.wlservices.org/proxy/pufepstm?mp=/stream"),
            ("icy.unitedradio.it/VirginRock80.", "Virgin Radio Rock '80", "http://icy.unitedradio.it/VirginRock80.mp3"),
            ("edge.radiomontecarlo.net/rmcweb008", "RMC 80", "http://edge.radiomontecarlo.net/rmcweb008"),
            ("streaming.centrosuono.com:8000/cssport.", "Centro Suono Sport", "http://streaming.centrosuono.com:8000/cssport.mp3"),
            ("sr6.inmystream.it:18102/stream", "Radio Radio Italia", "https://sr6.inmystream.it:18102/stream"),
            ("dreamsiteradiocp.com:8092/", "Radio Maria", "http://dreamsiteradiocp.com:8092/;"),
            ("icy.unitedradio.it/VirginHardRock.", "Virgin Radio Hard Rock", "http://icy.unitedradio.it/VirginHardRock.mp3"),
            ("wma08.fluidstream.net:3612/listen.pls", "Radio Kiss Kiss Napoli", "http://wma08.fluidstream.net:3612/;listen.pls"),
            ("wma06.fluidstream.net:3614/listen.pls", "Radio Kiss Kiss Italia", "http://wma06.fluidstream.net:3614/;listen.pls"),
            ("icecast.unitedradio.it/r101", "R101 FM", "http://icecast.unitedradio.it/r101"),
            ("icy.unitedradio.it/Virgin_06.", "Virgin Radio Rock Ballads", "http://icy.unitedradio.it/Virgin_06.mp3"),
            ("live.radioradicale.it/live.", "Radio Radicale", "http://live.radioradicale.it/live.mp3"),
            ("radioitaliasmi.akamaized.net/hls/live/2093120/RISMI/stream01/streamPlaylist.m3u8", "Radio Italia Solo Musica Italiana", "https://radioitaliasmi.akamaized.net/hls/live/2093120/RISMI/stream01/streamPlaylist.m3u8"),
            ("stream2.vivafm.it:8002/stream", "Radio Viva FM", "http://stream2.vivafm.it:8002/stream"),
            ("players.fluidstream.net/kisskissnetwork.pls", "Radio Kiss Kiss", "http://players.fluidstream.net/kisskissnetwork.pls"),
            
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
            ("kathy.torontocast.com:3330/stream/1/?esPlayer&cb=82181.", "Jazz Sakura", "http://kathy.torontocast.com:3330/stream/1/?esPlayer&cb=82181.mp3"),
            ("listen.moe/stream", "Listen.Moe JPop Vorbis", "https://listen.moe/stream"),
            ("nhkworld.webcdn.stream.ne.jp/www11/radiojapan/all/263949/live_s.m3u8", "NHK Wworld Radio Japan", "http://nhkworld.webcdn.stream.ne.jp/www11/radiojapan/all/263949/live_s.m3u8"),
            ("gyusyabu.ddo.jp:8000/listen.pls", "Retro PC GAME Radio", "http://gyusyabu.ddo.jp:8000/listen.pls"),
            ("stream.zeno.fm/qpn8mkt8c4duv", "Anime Para Ti", "https://stream.zeno.fm/qpn8mkt8c4duv"),
            ("stream.gensokyoradio.net/GensokyoRadio-enhanced.m3u", "Gensokyo Radio", "https://stream.gensokyoradio.net/GensokyoRadio-enhanced.m3u"),
            ("jenny.torontocast.com:8062/", "J1 Gold", "http://jenny.torontocast.com:8062/"),
            ("radio.kahoku.net:8000/", "FM Kahoku 78.7", "http://radio.kahoku.net:8000/;"),
            ("shonanbeachfm.out.airtime.pro:8000/shonanbeachfm_a", "Shonan Beach FM 78.9", "http://shonanbeachfm.out.airtime.pro:8000/shonanbeachfm_a"),
            ("jenny.torontocast.com:8056/", "J1 Hits", "http://jenny.torontocast.com:8056/"),
            ("nhkworld.webcdn.stream.ne.jp/www11/radiojapan/all/263943/live_s.m3u8", "NHK World Radio Japan", "https://nhkworld.webcdn.stream.ne.jp/www11/radiojapan/all/263943/live_s.m3u8"),
            ("rocafmadrid.radioca.st/", "Free FM Tokyo", "https://rocafmadrid.radioca.st/"),
            ("radio.plaza.one/opus", "Nightwave Plaza OPUS 96", "http://radio.plaza.one/opus"),
            ("61.89.201.27:8000/radikishi.", "Kishiwada Radio", "http://61.89.201.27:8000/radikishi.mp3"),
            ("stream.zeno.fm/p83d0vdp54zuv", "Tatsuro Yamashita Radio", "https://stream.zeno.fm/p83d0vdp54zuv"),
            ("voiceoftheplanet.out.airtime.pro:8000/voiceoftheplanet_a", "Voice of the Planet Ottava", "http://voiceoftheplanet.out.airtime.pro:8000/voiceoftheplanet_a"),
            ("rocafmadrid.radioca.st/stream", "Free FM Tokyo", "https://rocafmadrid.radioca.st/stream"),
            ("internet-radio.com/servers/tools/playlistgenerator/?u=uk5.internet-radio.com:8306/listen.pls&t=.m3u", "Moon Mission Recordings", "http://www.internet-radio.com/servers/tools/playlistgenerator/?u=http://uk5.internet-radio.com:8306/listen.pls&t=.m3u"),
            ("bluford.torontocast.com:8006/stream", "Tokyo Rose Radio", "http://bluford.torontocast.com:8006/stream"),
            ("dadamore2.ddo.jp:8000/", "Dada More", "http://dadamore2.ddo.jp:8000/"),
            ("ottava2.out.airtime.pro:8000/ottava2_a", "Ottava", "http://ottava2.out.airtime.pro:8000/ottava2_a"),
            ("streamer.radio.co/s83eb8ff39/listen", "Súper Tokio Radio", "https://streamer.radio.co/s83eb8ff39/listen"),
            ("play.streamafrica.net/JapanCityPop", "BOX : Japan City Pop", "https://play.streamafrica.net/JapanCityPop"),
            ("s10.webradio-hosting.com/proxy/fredradiojp/stream", "Fred Film Radio)", "https://s10.webradio-hosting.com/proxy/fredradiojp/stream"),
            ("antares.dribbcast.com/proxy/jpop?mp=/s", "Big B Radio - Jpop", "https://antares.dribbcast.com/proxy/jpop?mp=/s"),
            
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
            ("eu4.fastcast4u.com/proxy/stilradiomk?mp=/1", "STIL RADIO", "https://eu4.fastcast4u.com/proxy/stilradiomk?mp=/1"),
            ("eu4.fastcast4u.com/proxy/stilradiomk?mp=/stream/2/", "BISER RADIO", "https://eu4.fastcast4u.com/proxy/stilradiomk?mp=/stream/2/"),
            ("radiostream.neotel.mk/kanal103", "Kanal 103", "http://radiostream.neotel.mk/kanal103"),
            ("dreamsiteradiocp.com:8118/stream", "Radio Maria Macedonia", "http://dreamsiteradiocp.com:8118/stream"),
            ("antenna5stream.neotel.mk:8000/live128", "Antenna 5 Macedonia", "http://antenna5stream.neotel.mk:8000/live128"),
            ("liferadio.ddns.net:8000/", "Life Radio", "http://liferadio.ddns.net:8000/"),
            ("eu4.fastcast4u.com/proxy/metradio?mp=/1", "Metropolis Radio Network", "https://eu4.fastcast4u.com/proxy/metradio?mp=/1"),
            ("ugdfm-stream.ugd.edu.mk:8000/stream", "University Radio UGD FM", "http://ugdfm-stream.ugd.edu.mk:8000/stream"),
            ("radiostream.neotel.mk/justmusicradio", "Just Music Radio", "https://radiostream.neotel.mk/justmusicradio"),
            ("liderfm.ipradio.mk/", "Lider FM 107,4", "https://liderfm.ipradio.mk/"),
            ("skyradio.com.mk/listen.m3u", "Скај Радио", "https://skyradio.com.mk/listen.m3u"),
            ("iandonov.radioca.st/stream/1", "Bum Kumanovo", "http://iandonov.radioca.st/;stream/1"),
            ("securestreams4.autopo.st:1668/stream", "Urban FM 90.8 Skopje", "https://securestreams4.autopo.st:1668/stream"),
            ("s2.free-shoutcast.com/stream/18058", "Time FM Gevgelija", "https://s2.free-shoutcast.com/stream/18058"),
            ("88.85.99.2/live-128.", "Radio Buba Mara 105.2 FM", "http://88.85.99.2/live-128.mp3"),
            ("s32.myradiostream.com:16040/?type=http&nocache=1688299470?0.591044522318551", "Radio Meff", "https://s32.myradiostream.com:16040/;?type=http&nocache=1688299470?0.591044522318551"),
            ("eu.live.skyfolk.mk/live.m3u8", "SKY FOLK", "https://eu.live.skyfolk.mk/live.m3u8"),
            ("radiocnd.mms.mk/proxy/player/stream", "Канал 77 Радио Мрежа ", "https://radiocnd.mms.mk/proxy/player/stream"),
            ("ekspresradio.dyndns.org:8000/", "Експрес Радио 101.1 FM", "http://ekspresradio.dyndns.org:8000/"),
            ("online.radioroks.ua/RadioROKS_Ballads_HD", "Rock Ballads", "http://online.radioroks.ua/RadioROKS_Ballads_HD"),
            ("radiostream.neotel.mk/samomk", "Samo MK", "https://radiostream.neotel.mk/samomk"),
            ("jfm1.hostingradio.ru:14536/rock70.", "70s Rock ", "http://jfm1.hostingradio.ru:14536/rock70.mp3"),
            ("server.webnetradio.net:5490/stream?", "Radio Bravo Smooth Jazz", "http://server.webnetradio.net:5490/stream?"),
            ("live.mkdstream.com/listen/valan/valand", "Radio Valandovo ", "https://live.mkdstream.com/listen/valan/valand"),
            ("radiocnd.mms.mk/proxy/offnet/stream", "Radio Kanal 77", "https://radiocnd.mms.mk/proxy/offnet/stream"),
            ("radiofortuna.ipradio.mk/%22", "Radio Fortuna 96.8 FM", "https://radiofortuna.ipradio.mk/;*.mp3%22"),
            ("radiostar.pro/stream/mknarodna.php", "Star Radio", "https://radiostar.pro/stream/mknarodna.php"),
            ("eu4.fastcast4u.com/proxy/stilradiomk?mp=/stream/4/", "EX-YU Stil Trap", "https://eu4.fastcast4u.com/proxy/stilradiomk?mp=/stream/4/"),
            ("eu4.fastcast4u.com/proxy/stilradiomk?mp=/stream/3/", "Stil Radio MKD Narodna", "https://eu4.fastcast4u.com/proxy/stilradiomk?mp=/stream/3/"),
            
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
            ("eu8.fastcast4u.com:5068/", "Jazz Lounge", "http://eu8.fastcast4u.com:5068/;"),
            ("mediaprima.rastream.com/mediaprima-hotfm", "Hot FM", "http://mediaprima.rastream.com/mediaprima-hotfm"),
            ("mediaprima.rastream.com/mediaprima-onefm", "One FM", "http://mediaprima.rastream.com/mediaprima-onefm"),
            ("usa3.fastcast4u.com/proxy/jeifm?mp=/1", "Jei FM Klang Tamil Radio", "https://usa3.fastcast4u.com/proxy/jeifm?mp=/1"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/AI_FMAAC_SC", "AI FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/AI_FMAAC_SC"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/RADIO_KLASIK.", "Klasik FM 101.1 MHz", "http://playerservices.streamtheworld.com/api/livestream-redirect/RADIO_KLASIK.mp3"),
            ("mediaprima.rastream.com/mediaprima-flyfm", "FLY FM", "http://mediaprima.rastream.com/mediaprima-flyfm"),
            ("n09.rcs.revma.com/2u1n6dtbv4uvv/9_11l86ncot7z1w02/playlist.m3u8", "Melody FM Malaysia", "https://n09.rcs.revma.com/2u1n6dtbv4uvv/9_11l86ncot7z1w02/playlist.m3u8"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/NASIONAL_FM.", "Nasional FM 88,5 MHz", "http://playerservices.streamtheworld.com/api/livestream-redirect/NASIONAL_FM.mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/KELANTAN_FMAAC.", "Kelantan FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/KELANTAN_FMAAC.aac"),
            ("mediaprima.rastream.com/mediaprima-koolfm", "Buletin FM", "http://mediaprima.rastream.com/mediaprima-koolfm"),
            ("stream.zeno.fm/4s44thh7yf9uv", "Melayu Klasik", "https://stream.zeno.fm/4s44thh7yf9uv"),
            ("java.skychatz.org:8080/stream/1", "SkyChatz FM", "http://java.skychatz.org:8080/;stream/1"),
            ("stream-eu-a.rcs.revma.com/488kt4sbv4uvv/68_1txzsglqw5l3t02/playlist.m3u8", "HITZ Malaysia", "https://stream-eu-a.rcs.revma.com/488kt4sbv4uvv/68_1txzsglqw5l3t02/playlist.m3u8"),
            ("28103.live.streamtheworld.com/SURIA_FMAAC.", "Suria FM", "https://28103.live.streamtheworld.com/SURIA_FMAAC.aac"),
            ("167.114.131.90:5316/stream/1/", "Gegar Musik FM", "http://167.114.131.90:5316/stream/1/"),
            ("stream.zeno.fm/q6xy0didftcvv", "Rock Rock Kapak", "https://stream.zeno.fm/q6xy0didftcvv"),
            ("51.79.240.13:8000/", "Gegar FM", "http://51.79.240.13:8000/"),
            ("stream.zeno.fm/hiut6cwfoneuv", "Slow Rock 90'", "https://stream.zeno.fm/hiut6cwfoneuv"),
            ("radiorosak.radioca.st/stream", "Radio Rosak", "https://radiorosak.radioca.st/stream"),
            ("kcfm.org:8000/stream", "KCFM Radio", "http://www.kcfm.org:8000/stream"),
            ("n08a-eu.rcs.revma.com/azatk0tbv4uvv/8_1ksmof3jo7vso02/playlist.m3u8", "Sinar FM", "https://n08a-eu.rcs.revma.com/azatk0tbv4uvv/8_1ksmof3jo7vso02/playlist.m3u8"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/BFM.", "BFM 89.9 FM", "http://playerservices.streamtheworld.com/api/livestream-redirect/BFM.mp3"),
            ("stream.zeno.fm/sf5sbjnsjituv", "Rock Kapak", "https://stream.zeno.fm/sf5sbjnsjituv"),
            ("stream.zeno.fm/07wm0kur8k0uv", "CHEMOR FM DANGDUTMANIA", "https://stream.zeno.fm/07wm0kur8k0uv"),
            ("live.ltfmonline.com:8000/stream", "LTFM Radio", "http://live.ltfmonline.com:8000/stream"),
            ("167.114.131.90:5744/stream/1/", "Perindu FM", "http://167.114.131.90:5744/stream/1/"),
            ("167.114.131.90:6156/stream/1/", "Impian FM", "http://167.114.131.90:6156/stream/1/"),
            
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
            ("provisioning.streamtheworld.com/pls/LOS40_MEXICO.pls", "Los 40 Principales México", "http://provisioning.streamtheworld.com/pls/LOS40_MEXICO.pls"),
            ("s3.voscast.com:10038/", "BEAUTIFUL Instrumentals", "http://s3.voscast.com:10038/"),
            ("panel.retrolandigital.com/radio/8110/listen", "Café Romántico Radio", "https://panel.retrolandigital.com/radio/8110/listen"),
            ("streamingcwsradio20.com:9410/stream", "La Ranchera de Monterrey - 1050 AM", "http://streamingcwsradio20.com:9410/stream"),
            ("panel.retrolandigital.com/listen/cumbias_inmortales_radio/listen", "Cumbias Inmortales Radio", "https://panel.retrolandigital.com/listen/cumbias_inmortales_radio/listen"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XEPHAMAAC.", "SABROSITA Ciudad de México - 590 AM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XEPHAMAAC.aac"),
            ("162.244.81.98:8140/listen", "Oldies Internet Radio", "http://162.244.81.98:8140/listen"),
            ("provisioning.streamtheworld.com/pls/W_RADIOAAC.pls", "XEW-FM 96.9 MHz Radio", "http://provisioning.streamtheworld.com/pls/W_RADIOAAC.pls"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XHSHFMAAC.", "Amor Ciudad de México - 95.3 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XHSHFMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XHMFMAAC_SC.", "Noticias - 88.9 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XHMFMAAC_SC.aac"),
            ("65.21.202.84:8062/", "Panda Show Radio - Online - El Panda Zambrano - Ciudad de México", "http://65.21.202.84:8062/"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XELAMAAC.", "La Comadre Ciudad de México", "https://playerservices.streamtheworld.com/api/livestream-redirect/XELAMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/KEBUENAAAC.", "La Ke Buena Ciudad de México - 92.9 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/KEBUENAAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XERED_AMAAC.", "UNIVERSAL Ciudad de México - 88.1 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XERED_AMAAC.aac"),
            ("playerservices.streamtheworld.com/pls/XHEXA.pls", "XHEXA Exa FM 104.9 FM", "http://playerservices.streamtheworld.com/pls/XHEXA.pls"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XHDFMFMAAC.", "MIX Ciudad de México - 106.5 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XHDFMFMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XEJP_AM_SC", "El Fonógrafo", "https://playerservices.streamtheworld.com/api/livestream-redirect/XEJP_AM_SC"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XEQR_FMAAC.", "La Z Ciudad de México - 107.3 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XEQR_FMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XHQQ_FMAAC.", "BANDA 93.3 (Monterrey) - 93.3 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XHQQ_FMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XEFRAMAAC_SC.", "Radio Felicidad Ciudad de México - 1180 AM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XEFRAMAAC_SC.aac"),
            ("quevivamexico.com/listen.pls", "Que Viva México", "http://quevivamexico.com/listen.pls"),
            ("162.244.81.98:8130/listen", "Instrumental Hits Radio", "http://162.244.81.98:8130/listen"),
            ("playerservices.streamtheworld.com/pls/XLTNFMAAC.pls", "XLTN Radio Latina 104.5 FM", "http://playerservices.streamtheworld.com/pls/XLTNFMAAC.pls"),
            ("xxdelgado.radioca.st/", "Roca Fm Clasicos Mexico", "https://xxdelgado.radioca.st/"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XEFRAMAAC.", "Radio Felicidad - 1180 AM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XEFRAMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/ACIR34_s01AAC.", "Llegó El Mariachi", "https://playerservices.streamtheworld.com/api/livestream-redirect/ACIR34_s01AAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XHFAJ_FMAAC.", "ALFA 91.3 FM (Ciudad de México", "https://playerservices.streamtheworld.com/api/livestream-redirect/XHFAJ_FMAAC.aac"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XERCFM_SC", "La Mejor Ciudad de México - 97.7 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XERCFM_SC"),
            ("playerservices.streamtheworld.com/pls/SAM07AAC286.pls", "Rock Radio Online Mexico", "http://playerservices.streamtheworld.com/pls/SAM07AAC286.pls"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/XEN_AM_SC", "El Fonógrafo - 690 AM", "https://playerservices.streamtheworld.com/api/livestream-redirect/XEN_AM_SC"),
            
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
            ("tachyon.shoutca.st:8303/xstream", "Radio D Plus", "http://tachyon.shoutca.st:8303/xstream"),
            ("eu2.fastcast4u.com/proxy/mic0?1611144786324=&mp=/stream", "Drugacija Radio Stanica live", "https://eu2.fastcast4u.com/proxy/mic0?1611144786324=&mp=/stream"),
            ("tachyon.shoutca.st:8289/xstream", "Radio D Live", "http://tachyon.shoutca.st:8289/xstream"),
            ("eu7.fastcast4u.com:6166", "City Radio 93.3 FM", "http://eu7.fastcast4u.com:6166/;"),
            ("radio.elmag.me/el", "El Radio live", "http://radio.elmag.me/el.mp3"),
            ("radiodux.me:8000/radiodux", "Radio DUX live", "http://www.radiodux.me:8000/radiodux"),
            ("player.reggaeneracija.me/proxy/reggaeneracija/stream", "Radio Reggaeneracija", "https://player.reggaeneracija.me/proxy/reggaeneracija/stream"),
            ("malta1491.startdedicated.de:8443/main", "Radio Porto Montenegro", "https://malta1491.startdedicated.de:8443/main"),
            ("213.239.205.210:8094/stream", "Radio Bijelo Polje", "http://213.239.205.210:8094/stream"),
            ("radioservis.me:8010/antenamlive", "Antena M Radio", "https://radioservis.me:8010/antenamlive"),
            ("realfm.net:8443/rfnr", "Real FM Radio", "https://realfm.net:8443/rfnr"),
            
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
            ("italo.live-streams.nl/fantasy", "Fantasy Italo Radio", "https://italo.live-streams.nl/fantasy"),
            ("intenseradio.live-streams.nl:8000/main", "Intense Radio", "http://intenseradio.live-streams.nl:8000/main"),
            ("mediaserv38.live-streams.nl:18030/stream", "Synthetic FM", "https://mediaserv38.live-streams.nl:18030/stream"),
            ("icecast.omroep.nl/radio1-bb-", "NPO Radio 1", "http://icecast.omroep.nl/radio1-bb-mp3"),
            ("icecast.omroep.nl/radio2-bb-", "NPO Radio 2", "http://icecast.omroep.nl/radio2-bb-mp3"),
            ("stream.gal.io/arrow", "Arrow Classic Rock", "http://stream.gal.io/arrow"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/RADIO10.", "Radio 10", "http://playerservices.streamtheworld.com/api/livestream-redirect/RADIO10.mp3"),
            ("icecast.omroep.nl/radio5-bb-", "NPO Radio 5", "https://icecast.omroep.nl/radio5-bb-mp3"),
            ("mediaserv33.live-streams.nl:8036/live", "Hi On Line Lounge Radio", "http://mediaserv33.live-streams.nl:8036/live"),
            ("icecast.omroep.nl/radio6-bb-", "NPO Radio 2 Soul & Jazz", "http://icecast.omroep.nl/radio6-bb-mp3"),
            ("stream.slam.nl/slam", "SLAM!", "http://stream.slam.nl/slam"),
            ("streams.greenhost.nl:8080/barok", "Concertzender Baroque", "http://streams.greenhost.nl:8080/barok"),
            ("stream.player.arrow.nl/arrowcr", "Arrow Classic Rock", "https://stream.player.arrow.nl/arrowcr"),
            ("radio-nostalgia.nl/nostalgia.asx", "Radio Nostalgia", "https://radio-nostalgia.nl/nostalgia.asx"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/SRGSTR04.", "Sky Radio 80's Hits", "http://playerservices.streamtheworld.com/api/livestream-redirect/SRGSTR04.mp3"),
            ("s45.myradiostream.com:18304/", "C-Dance RETRO", "http://s45.myradiostream.com:18304/"),
            ("icecast-qmusicnl-cdp.triple-it.nl/Qmusic_nl_live_96.", "Qmusic", "https://icecast-qmusicnl-cdp.triple-it.nl/Qmusic_nl_live_96.mp3"),
            ("icecast.omroep.nl/radio4-bb-", "NPO Radio 4", "http://icecast.omroep.nl/radio4-bb-mp3"),
            ("mediaserv38.live-streams.nl:8006/", "Hi On Line Jazz Radio", "http://mediaserv38.live-streams.nl:8006/"),
            ("25283.live.streamtheworld.com/RADIO538.", "Radio 538", "https://25283.live.streamtheworld.com/RADIO538.mp3"),
            ("icecast.omroep.nl/3fm-bb-", "NPO 3FM Serious Radio", "http://icecast.omroep.nl/3fm-bb-mp3"),
            ("stream.radiocontinu.nl/radiocontinu", "Radio Continu", "http://stream.radiocontinu.nl/radiocontinu"),
            ("shoutcast1.hardcoreradio.nl/", "Hardcore Radio", "http://shoutcast1.hardcoreradio.nl/"),
            ("stream.bnr.nl/bnr__96_20", "BNR Nieuwsradio", "https://stream.bnr.nl/bnr_aac_96_20"),
            ("stream.radiocorp.nl/web10_", "SLAM! Non Stop", "http://stream.radiocorp.nl/web10_mp3"),
            ("streams.greenhost.nl:8080/oudemuziek", "Concertzender Oude Muziek", "http://streams.greenhost.nl:8080/oudemuziek"),
            
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
            ("ais-nzme.streamguys1.com/nz_002_", "Newstalk ZB Auckland", "https://ais-nzme.streamguys1.com/nz_002_aac"),
            ("radionz-ice.streamguys.com/national.", "RNZ National", "http://radionz-ice.streamguys.com/national.mp3"),
            ("procyon.shoutca.st:8032/", "Easy 80s", "http://procyon.shoutca.st:8032/;"),
            ("radio.wanderingsheep.tv:8021/christianjazz", "Wandering Sheep Radio - Christian Smooth Jazz", "http://radio.wanderingsheep.tv:8021/christianjazz"),
            ("streaming.radiomyway.co.nz/coast2.pls", "Coast", "http://streaming.radiomyway.co.nz/coast2.pls"),
            ("streaming.radiomyway.co.nz/zbwnalt.pls", "Newstalk ZB Wellington", "http://streaming.radiomyway.co.nz/zbwnalt.pls"),
            ("radionz-ice.streamguys.com/international.", "RNZ - Radio", "http://radionz-ice.streamguys.com/international.mp3"),
            ("ais-nzme.streamguys1.com/nz_009_", "Radio Hauraki", "https://ais-nzme.streamguys1.com/nz_009_aac"),
            ("ais-nzme.streamguys1.com/nz_020_", "The Hits 89.6 Nelson", "http://ais-nzme.streamguys1.com/nz_020_aac"),
            ("wowza.iwi.radio/icecast-to-hls/ngrp:NgatiPorou.stream/playlist.m3u8", "Radio Ngāti Porou", "https://wowza.iwi.radio/icecast-to-hls/ngrp:NgatiPorou.stream/playlist.m3u8"),
            ("s2.stationplaylist.com:9000/gaiafm.", "Gaia FM New Zealand", "http://s2.stationplaylist.com:9000/gaiafm.aac"),
            ("cast4.asurahosting.com:2199/tunein/sleeprad.pls", "Sleep Radio", "https://cast4.asurahosting.com:2199/tunein/sleeprad.pls"),
            ("ais-nzme.streamguys1.com/nz_015_", "GOLD 105.4 Auckland", "http://ais-nzme.streamguys1.com/nz_015_aac"),
            ("18743.live.streamtheworld.com/GEORGEFM_CC_S01.", "George FM Club Classics", "https://18743.live.streamtheworld.com/GEORGEFM_CC_S01.aac"),
            ("radio.wanderingsheep.tv:8000/jazzcafe", "Wandering Sheep Radio - Jazz Cafe", "http://radio.wanderingsheep.tv:8000/jazzcafe"),
            ("24973.live.streamtheworld.com/GEORGE_DNB_S01.", "George FM", "https://24973.live.streamtheworld.com/GEORGE_DNB_S01.aac"),
            ("radionz-ice.streamguys.com/international_64", "RNZ Pacific", "http://radionz-ice.streamguys.com/international_aac64"),
            ("streaming.radiomyway.co.nz/zbchalt.pls", "Newstalk ZB", "http://streaming.radiomyway.co.nz/zbchalt.pls"),
            ("radiorockfm.co.nz:8000/listenlive", "Radio Rock FM", "http://www.radiorockfm.co.nz:8000/listenlive"),
            ("stream.basefm.co.nz:8000/BaseHi", "Base FM", "http://stream.basefm.co.nz:8000/BaseHi"),
            ("sen.streamguys1.com/SENZ-AAC/playlist.m3u8", "SENZ - New Zealand", "https://sen.streamguys1.com/SENZ-AAC/playlist.m3u8"),
            ("ais-nzme.streamguys1.com/nz_116_", "Radio Tarana", "http://ais-nzme.streamguys1.com/nz_116_aac"),
            ("edge.iono.fm/xice/49_high.", "Classic 102.7 FM", "http://edge.iono.fm/xice/49_high.aac"),
            ("ais-nzme.streamguys1.com/nz_010_", "Flava", "https://ais-nzme.streamguys1.com/nz_010_aac"),
            ("radionz-ice.streamguys.com/concert.", "RNZ - Radio New Zealand Classic", "http://radionz-ice.streamguys.com/concert.mp3"),
            ("stream9.broadcast.co.nz:8000/radiospicewebsiteaudio.", "Radio Spice", "http://stream9.broadcast.co.nz:8000/radiospicewebsiteaudio.mp3"),
            ("s8.myradiostream.com:58408/", "BeachFM 106.3", "http://s8.myradiostream.com:58408/"),
            ("radionz-ice.streamguys.com/fallback-concert_128", "RNZ Concert ", "http://radionz-ice.streamguys.com/fallback-concert_aac128"),
            ("stream.3abnaustralia.org.au:8443/stream", "3ABN Christian Radio", "https://stream.3abnaustralia.org.au:8443/stream"),
            
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
    
    // Panama
    static func addDefaultStationsForPanama(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("provisioning.streamtheworld.com/pls/LOS40_PAN.pls", "Los 40 Principales Panamá", "http://provisioning.streamtheworld.com/pls/LOS40_PAN.pls"),
            ("ic.streann.com:8000/disneypanama", "Radio Disney Panamá", "http://ic.streann.com:8000/disneypanama"),
            ("dreamsiteradiocp.com:8082/stream", "Radio Maria Panama", "http://dreamsiteradiocp.com:8082/stream"),
            ("rosetta.shoutca.st:9264/stream", "AM Original 1180 Veraguas", "http://rosetta.shoutca.st:9264/stream"),
            ("provisioning.streamtheworld.com/pls/COOLFMAAC.pls", "Cool FM 89.3 Panama City", "http://provisioning.streamtheworld.com/pls/COOLFMAAC.pls"),
            ("rosetta.shoutca.st:8931/", "Original Stereo 90.7 FM", "http://rosetta.shoutca.st:8931/;"),
            ("stm1.tropicalmoonmedia.com:7006/stream", "Cool Jazz FM (Tropical Moon)", "https://stm1.tropicalmoonmedia.com:7006/stream"),
            ("stream.mixesurbanospty.com:8020/blasturbana.", "Blast panama", "https://stream.mixesurbanospty.com:8020/blasturbana.mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/ANT8AAC.", "Antena 8 100.1 FM", "https://playerservices.streamtheworld.com/api/livestream-redirect/ANT8AAC.aac"),
            ("streaming507.net:8020/stream", "LIKE 105 FM", "https://www.streaming507.net:8020/stream"),
            ("cloudstream2036.conectarhosting.com/8018/stream", "Bendicion Radio 1380 AM", "https://cloudstream2036.conectarhosting.com/8018/stream"),
            ("laradiossl.online:10355/stream.nsv", "Rumba FM", "https://laradiossl.online:10355/;stream.nsv"),
            ("sp2.servidorrprivado.com/8094/stream", "CPR LA PRIMERA 101.1 FM", "https://sp2.servidorrprivado.com/8094/stream"),
            ("radios.host-pa.com:8046/", "CHT FM 107.7", "https://radios.host-pa.com:8046/;"),
            ("dallas.myautodj.com:2199/proxy/toneflame/stream", "ToneFlame Urban Radio", "https://dallas.myautodj.com:2199/proxy/toneflame/stream"),
            ("pcbrothers.net/8002/stream", "Crisol FM", "https://pcbrothers.net/8002/stream"),
            
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Panama" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Panama");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Peru
    static func addDefaultStationsForPeru(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("playerservices.streamtheworld.com/pls/MAG_AAC.pls", "Radio Mágica 88.3 FM", "http://playerservices.streamtheworld.com/pls/MAG_AAC.pls"),
            ("playerservices.streamtheworld.com/pls/CRP_PLA.pls", "Radio Planeta 107.7 FM", "http://playerservices.streamtheworld.com/pls/CRP_PLA.pls"),
            ("provisioning.streamtheworld.com/pls/CRP_LI.pls", "Radio La Inolvidable", "http://provisioning.streamtheworld.com/pls/CRP_LI.pls"),
            ("24943.live.streamtheworld.com/CRP_LI_SC?", "RADIO LA INOLVIDABLE 93.7 FM", "https://24943.live.streamtheworld.com/CRP_LI_SC?"),
            ("playerservices.streamtheworld.com/pls/CRP_RIT.pls", "Radio Ritmo Romántica", "http://playerservices.streamtheworld.com/pls/CRP_RIT.pls"),
            ("online.radiodifusion.net:8020/stream", "Top Latino", "http://online.radiodifusion.net:8020/stream"),
            ("24933.live.streamtheworld.com/CRP_NQ_SC?", "RADIO NUEVA Q 107.1 FM", "https://24933.live.streamtheworld.com/CRP_NQ_SC?"),
            ("playerservices.streamtheworld.com/pls/CRP_NQ.pls", "Radio Nueva Q", "http://playerservices.streamtheworld.com/pls/CRP_NQ.pls"),
            ("mdstrm.com/audio/5fab0687bcd6c2389ee9480c/live.m3u8", "Radio Oxígeno", "https://mdstrm.com/audio/5fab0687bcd6c2389ee9480c/live.m3u8"),
            ("25063.live.streamtheworld.com/CRP_MOD_SC?", "RADIO MODA 97.3 FM", "https://25063.live.streamtheworld.com/CRP_MOD_SC?"),
            ("playerservices.streamtheworld.com/m3u/CRP_MARAAC.m3u", "Radiomar Plus 106.3", "http://playerservices.streamtheworld.com/m3u/CRP_MARAAC.m3u"),
            ("us-b4-p-e-pb13-audio.cdn.mdstrm.com/live-audio-aw/5fada56fe4e09508207a7951?", "RADIO LA MEGA 96.7 FM", "https://us-b4-p-e-pb13-audio.cdn.mdstrm.com/live-audio-aw/5fada56fe4e09508207a7951?"),
            ("167.114.118.120:7246/", "Radio Vinilo - Lima", "http://167.114.118.120:7246/;"),
            ("cloud9.ldwebstudios.net:7000/", "Radio Huancayo", "https://cloud9.ldwebstudios.net:7000/;"),
            ("25093.live.streamtheworld.com/MAG_SC?", "RADIO MAGICA 88.3 FM", "https://25093.live.streamtheworld.com/MAG_SC?"),
            ("n06.radiojar.com/2fse67zuv8hvv?1669054401=&rj-tok=AAABhJtuNOUAIi7Le3h5PA-2VA&rj-ttl=5", "PBO Radio", "http://n06.radiojar.com/2fse67zuv8hvv?1669054401=&rj-tok=AAABhJtuNOUAIi7Le3h5PA-2VA&rj-ttl=5"),
            ("167.114.118.120:7628/", "Radio Pirata Mix - Cajabamba", "http://167.114.118.120:7628/;"),
            ("mdstrm.com/audio/5fada56fe4e09508207a7951/icecast.audio", "Radio La Mega", "https://mdstrm.com/audio/5fada56fe4e09508207a7951/icecast.audio"),
            ("mdstrm.com/audio/5fada514fc16c006bd63370f/icecast.audio", "Radio Corazón (94.3 FM Lima)", "https://mdstrm.com/audio/5fada514fc16c006bd63370f/icecast.audio"),
            ("mdstrm.com/audio/5fada553978fe1080e3ac5ea/icecast.audio", "Studio 92 (92.5 FM Lima)", "https://mdstrm.com/audio/5fada553978fe1080e3ac5ea/icecast.audio"),
            ("oyotunstream.com:7066/", "Radio frecuencia 100 - Trujillo", "http://oyotunstream.com:7066/;"),
            ("94.23.159.187:9950/", "Radio Los Angeles - Chepen", "http://94.23.159.187:9950/;"),
            ("mdstrm.com/audio/5fab3416b5f9ef165cfab6e9/icecast.audio", "Radio RPP Noticias", "https://mdstrm.com/audio/5fab3416b5f9ef165cfab6e9/icecast.audio"),
            ("167.114.118.119:7494/", "Radio Bahía 103.1 FM", "http://167.114.118.119:7494/;"),
            ("167.114.118.120:7112/", "Radio Marañon 96.1 FM", "http://167.114.118.120:7112/;"),
            ("tupanel.info:8290/stream?icy=http", "Full Techno", "https://tupanel.info:8290/stream?icy=http"),
            ("5c3fb01839654.streamlock.net:1963/ipradioovacion1/liveovacion1radio/playlist.m3u8", "Ovación 620 AM", "https://5c3fb01839654.streamlock.net:1963/ipradioovacion1/liveovacion1radio/playlist.m3u8"),
            ("167.114.118.120:7216/", "Radio Zona 5 93.3", "http://167.114.118.120:7216/;"),
            
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
            ("195.150.20.242:8000/rmf_fm", "RMF FM", "http://195.150.20.242:8000/rmf_fm"),
            ("zet-net-01.cdn.eurozet.pl:8400/", "Radio Zet", "http://zet-net-01.cdn.eurozet.pl:8400/"),
            ("stream.open.fm/368?type=.&user=800043471858&player_group=WWW", "Radio Nowy Świat", "https://stream.open.fm/368?type=.aac&user=800043471858&player_group=WWW"),
            ("n-4-2.dcs.redcdn.pl/sc/o2/Eurozet/live/antyradio.livx?audio=5", "Antyradio", "https://n-4-2.dcs.redcdn.pl/sc/o2/Eurozet/live/antyradio.livx?audio=5"),
            ("193.222.135.71/378", "Radio 357", "http://193.222.135.71/378"),
            ("stream.open.fm/201", "Radio Złote Przeboje", "https://stream.open.fm/201"),
            ("stream.open.fm/3", "80s Hits - Open FM", "https://stream.open.fm/3"),
            ("stream3.polskieradio.pl:8080/.", "Polskie Radio 24", "http://stream3.polskieradio.pl:8080/;.mp3"),
            ("stream.open.fm/81", "500 Party Hits FM", "https://stream.open.fm/81"),
            (".polskieradio.pl:8900/.", "Polskie Radio Jedynka", "http://mp3.polskieradio.pl:8900/;.mp3"),
            ("stream.open.fm/27", "OpenFM - Italo Disco", "http://stream.open.fm/27"),
            ("31.192.216.8/RMFCLASSIC48", "RMF Classic", "http://31.192.216.8/RMFCLASSIC48"),
            ("195.150.20.8/PPRZEBOJE", "RMF Polskie przeboje", "http://195.150.20.8/PPRZEBOJE"),
            ("stream.open.fm/108", "OpenFM - Classic Metal", "http://stream.open.fm/108"),
            ("stream3.polskieradio.pl:8904/", "Trojka", "http://stream3.polskieradio.pl:8904/"),
            ("31.192.216.7/90S", "RMF 90s", "http://31.192.216.7/90S"),
            ("r.dcs.redcdn.pl/sc/o2/Eurozet/live/audio.livx?audio=5", "Radio ZET", "https://r.dcs.redcdn.pl/sc/o2/Eurozet/live/audio.livx?audio=5"),
            ("31.192.216.10/DANCE", "RMF Dance", "http://31.192.216.10/DANCE"),
            ("djmixes.radioparty.pl:8035/", "Radioparty.pl Dj Mixes Party", "http://djmixes.radioparty.pl:8035/"),
            (".polskieradio.pl:8900/", "Polskie Radio Program 1", "http://mp3.polskieradio.pl:8900/"),
            ("stream.open.fm/21", "OpenFM - Disco Polo", "http://stream.open.fm/21"),
            ("stream.open.fm/31", "OpenFM - Dance", "http://stream.open.fm/31"),
            ("stream.open.fm/5", "OpenFM - House", "http://stream.open.fm/5"),
            ("pl2-play.adtonos.com/zote-przeboje", "Radio Zlote Przeboje", "https://pl2-play.adtonos.com/zote-przeboje"),
            ("stream.open.fm/7", "OpenFM - Trance", "http://stream.open.fm/7"),
            ("rs9-krk2-cyfronet.rmfstream.pl/RMFMAXXX48", "Radio RMF MAXXX", "https://rs9-krk2-cyfronet.rmfstream.pl/RMFMAXXX48"),
            ("stream.open.fm/2", "OpenFM - Impreza", "http://stream.open.fm/2"),
            ("stream3.polskieradio.pl:8956/", "Polskie Radio - Czwórka", "http://stream3.polskieradio.pl:8956/;"),
            ("stream3.polskieradio.pl:8906/stream", "Polskie Radio - Czwórka", "http://stream3.polskieradio.pl:8906/;stream"),
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
            ("centova.radios.pt:8401/listen.pls", "ORBITAL", "http://centova.radios.pt:8401/;listen.pls"),
            ("tsfdirecto.tsf.pt/tsfdirecto.", "TSF Rádio Notícias", "http://tsfdirecto.tsf.pt/tsfdirecto.mp3"),
            ("195.23.85.126:8455/listen.pls?sid=1", "Rádio Observador", "http://195.23.85.126:8455/listen.pls?sid=1"),
            ("provisioning.streamtheworld.com/pls/RADIO_RENASCENCA.pls", "Rádio Renascença", "http://provisioning.streamtheworld.com/pls/RADIO_RENASCENCA.pls"),
            ("23603.live.streamtheworld.com/RFMAAC.", "RFM", "https://23603.live.streamtheworld.com/RFMAAC.aac"),
            ("streaming-live.rtp.pt/liveradio/antena180a/playlist.m3u8", "Antena 1", "https://streaming-live.rtp.pt/liveradio/antena180a/playlist.m3u8"),
            ("provisioning.streamtheworld.com/pls/mega_hits.pls", "Mega Hits", "http://provisioning.streamtheworld.com/pls/mega_hits.pls"),
            ("109.71.41.6:8046/stream", "The VIBE - Dancefloor Radio", "http://109.71.41.6:8046/stream"),
            ("185.32.188.17:8097/stream", "Rap/Hip Hop", "http://185.32.188.17:8097/stream"),
            ("centova.radio.com.pt:9496/", "Rádio Amália", "http://centova.radio.com.pt:9496/;"),
            ("streaming-live.rtp.pt/liveradio/rdpafrica80a/playlist.m3u8", "RDP Africa", "https://streaming-live.rtp.pt/liveradio/rdpafrica80a/playlist.m3u8"),
            ("centova.radio.com.pt:9478/", "Rádio Nova Era", "http://centova.radio.com.pt:9478/"),
            ("s3.viastreaming.net:8525/", "Deep in Radio", "http://s3.viastreaming.net:8525/"),
            ("live.top80.fm:8086/", "TOP 80 - Todos Os Exitos 80s", "http://live.top80.fm:8086/"),
            ("109.71.41.6:8026/stream", "Rádio Planície 92.8 FM", "http://109.71.41.6:8026/stream"),
            ("proic1.evspt.com/radar_", "RADAR 97.8 FM", "https://proic1.evspt.com/radar_aac"),
            ("centova.radio.com.pt:8547/", "ABC Portugal", "http://centova.radio.com.pt:8547/;"),
            ("radio.streemlion.com:1150/stream", "4Drive Jazz", "http://radio.streemlion.com:1150/stream"),
            ("centova.radio.com.pt:9528/", "Rádio Nova 98.9 FM", "http://centova.radio.com.pt:9528/"),
            ("centova.radio.com.pt:8495/", "Rádio MEO Music", "http://centova.radio.com.pt:8495/;"),
            ("stream-icy.bauermedia.pt/m80.", "M80 rádio", "http://stream-icy.bauermedia.pt/m80.mp3"),
            ("centova.radio.com.pt:8499/", "Rádio Marginal", "http://centova.radio.com.pt:8499/;"),
            ("centova.radio.com.pt:9520/", "Rádio Festival do Norte", "http://centova.radio.com.pt:9520/;"),
            ("stream-hls.bauermedia.pt/comercial./playlist.m3u8", "Rádio Comercial", "https://stream-hls.bauermedia.pt/comercial.aac/playlist.m3u8"),
            ("proic1.evspt.com/oxigenio_", "Oxigénio 102.6", "https://proic1.evspt.com/oxigenio_aac"),
            ("centova.radio.com.pt:8485/", "Rádio Regional de Arouca", "http://centova.radio.com.pt:8485/;"),
            ("195.23.85.126:9500/", "Hiper FM", "http://195.23.85.126:9500/;"),
            ("centova.radio.com.pt:9460/", "Diana FM", "http://centova.radio.com.pt:9460/;"),
            ("nl.digitalrm.pt:8048/stream", "Radio Fado de Coimbra", "https://nl.digitalrm.pt:8048/stream"),
            
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
    
    // Romania
    static func addDefaultStationsForRomania(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("89.238.227.6:8006/", "Radio Romania Actualități", "http://89.238.227.6:8006/;"),
            ("live.magicfm.ro:9128/magicfm.p", "Magic FM", "http://live.magicfm.ro:9128/magicfm.aacp"),
            ("edge126.rdsnet.ro:84/profm/dancefm.", "Dance FM 89.5 Bucharest", "http://edge126.rdsnet.ro:84/profm/dancefm.mp3"),
            ("live.dancemusic.ro:7000/listen.pls?sid=1", "Deep House Radio - Bucharest Romania", "http://live.dancemusic.ro:7000/listen.pls?sid=1"),
            ("astreaming.europafm.ro:8000/europafm_p48k", "Europa FM", "http://astreaming.europafm.ro:8000/europafm_aacp48k"),
            ("a.fmradiomanele.ro:8054/", "Radio Manele FM", "http://a.fmradiomanele.ro:8054/;"),
            ("edge76.rdsnet.ro:84/digifm/digifm.", "DIGI FM", "http://edge76.rdsnet.ro:84/digifm/digifm.mp3"),
            ("live.rockfm.ro:9128/rockfm.p", "Rock FM Romania", "http://live.rockfm.ro:9128/rockfm.aacp"),
            ("edge126.rdsnet.ro:84/profm/profm.", "Pro FM", "http://edge126.rdsnet.ro:84/profm/profm.mp3"),
            ("kissfm.ro/listen.pls", "Kiss Fm Ro", "https://www.kissfm.ro/listen.pls"),
            ("live.guerrillaradio.ro:8010/guerrilla.", "Radio Guerrilla", "http://live.guerrillaradio.ro:8010/guerrilla.aac"),
            ("live.playradio.org:9090/90HD", "Play 90's", "http://live.playradio.org:9090/90HD"),
            ("live.radiocafe.ro:8048/live.", "Radio Cafe Romania", "http://live.radiocafe.ro:8048/live.aac"),
            ("80.86.106.110:8002/", "GoldFM", "http://80.86.106.110:8002/"),
            ("live.radiolautaru.ro:9000/stream.nsv", "Lautaru Populara", "http://live.radiolautaru.ro:9000/;stream.nsv"),
            ("virginradio.ro/VirginRadioRomania-live.m3u", "Virgin Radio Romania", "http://virginradio.ro/VirginRadioRomania-live.m3u"),
            ("zuicast.digitalag.ro:9420/zu", "Radio Zu", "http://zuicast.digitalag.ro:9420/zu"),
            ("stream2.srr.ro:8012/", "Radio România Cultural", "http://stream2.srr.ro:8012/"),
            ("37.251.146.169:8300/stream", "Radio Clasic Mozart", "http://37.251.146.169:8300/stream"),
            ("89.238.227.6:8042/", "Antena satelor", "http://89.238.227.6:8042/"),
            ("zuicast.digitalag.ro:9420/romanticfm", "Romantic FM", "http://zuicast.digitalag.ro:9420/romanticfm"),
            ("37.251.146.169:8204/stream", "Radio Clasic 100% Romanesc", "http://37.251.146.169:8204/stream"),
            ("stream2.srr.ro:8078/eteatru.", "Eteatru", "http://stream2.srr.ro:8078/eteatru.mp3"),
            ("asculta.rfi.ro:9128/live.", "RFI Romania", "http://asculta.rfi.ro:9128/live.aac"),
            ("81.196.25.70:8000/", "Radio Trinitas", "http://81.196.25.70:8000/"),
            ("37.251.146.169:7200/stream", "Radio Clasic Beethoven", "http://37.251.146.169:7200/stream"),
            ("37.251.146.169:8024/stream", "Radio Clasic Chopin", "http://37.251.146.169:8024/stream"),
            ("89.39.189.52:8000/", "Gherla FM", "http://89.39.189.52:8000/;"),
            ("stream2.srr.ro:8016/", "Radio România Cultural", "http://stream2.srr.ro:8016/"),
            ("1stream2.srr.ro:8026/", "Radio România Muzical", "http://stream2.srr.ro:8026/"),
        ]
        
        let existingStations = Set(viewModel.stations.filter { $0.country == "Romania" }.map { $0.id })
        let missingStations = defaultStations.filter { !existingStations.contains($0.0) }
        
        var newStations = [RadioStation]()
        
        for station in missingStations {
            let iconData = viewModel.loadImageData(named: station.1)
            let newStation = RadioStation(id: station.0, name: station.1, url: station.2, iconData: iconData, country: "Romania");
            viewModel.stations.append(newStation)
            newStations.append(newStation)
        }
    }
    
    // Russia
    static func addDefaultStationsForRussia(to viewModel: RadioStationViewModel) {
        let defaultStations = [
            ("ep256.hostingradio.ru:8052/europaplus256.", "Europa Plus", "http://ep256.hostingradio.ru:8052/europaplus256.mp3"),
            ("nashe1.hostingradio.ru/rock-128.", "ROCK FM", "http://nashe1.hostingradio.ru/rock-128.mp3"),
            ("dfm-disc90.hostingradio.ru/disc9096.p", "DFM Дискач 90-х", "https://dfm-disc90.hostingradio.ru/disc9096.aacp"),
            ("icecast.vgtrk.cdnvideo.ru/vestifm__192kbps", "Вести ФМ (Vesti FM)", "http://icecast.vgtrk.cdnvideo.ru/vestifm_mp3_192kbps"),
            ("retroserver.streamr.ru:8043/retro256.", "Ретро FM", "http://retroserver.streamr.ru:8043/retro256.mp3"),
            ("dfm-dfmrusdance.hostingradio.ru/dfmrusdance96.p?0.9987259013359274", "DFM RUSSIAN DANCE", "https://dfm-dfmrusdance.hostingradio.ru/dfmrusdance96.aacp?0.9987259013359274"),
            ("chanson.hostingradio.ru:8041/chanson128.", "Шансон Радио", "http://chanson.hostingradio.ru:8041/chanson128.mp3"),
            ("dorognoe.hostingradio.ru:8000/dorognoe", "дорожное радио (Dorognoe Radio)", "http://dorognoe.hostingradio.ru:8000/dorognoe"),
            ("listen.rusongs.ru/ru--128", "Радио Русские Песни", "http://listen.rusongs.ru/ru-mp3-128"),
            ("dorognoe.hostingradio.ru:8000/radio", "Дорожное радио", "http://dorognoe.hostingradio.ru:8000/radio"),
            ("ic4.101.ru:8000/v3_1", "Авторадио - FM 90.3 - Москва", "http://ic4.101.ru:8000/v3_1"),
            ("radio-holding.ru:9000/marusya__64", "Маруся FM", "http://radio-holding.ru:9000/marusya_aac_64"),
            ("nashe1.hostingradio.ru/nashe-128.", "Nashe Radio", "http://nashe1.hostingradio.ru/nashe-128.mp3"),
            ("icecast-radiovanya.cdnvideo.ru/radiovanya", "РАДИО ВАНЯ", "https://icecast-radiovanya.cdnvideo.ru/radiovanya"),
            ("ic6.101.ru:8000/stream/air64/202", "Comedy Radio new link", "http://ic6.101.ru:8000/stream/air/aac/64/202"),
            ("ep128server.streamr.ru:8030/ep128", "Европа плюс", "http://ep128server.streamr.ru:8030/ep128"),
            ("icecast.vgtrk.cdnvideo.ru/vestifm", "Вести FM", "http://icecast.vgtrk.cdnvideo.ru/vestifm"),
            ("icecast.vgtrk.cdnvideo.ru/mayakfm__192kbps", "Радио Маяк (Radio Mayak)", "http://icecast.vgtrk.cdnvideo.ru/mayakfm_mp3_192kbps"),
            ("radiorecord.hostingradio.ru/rus96.p", "Radio Record - Russian Mix", "https://radiorecord.hostingradio.ru/rus96.aacp"),
            ("8bit.fm:8000/live", "8bitFM", "http://8bit.fm:8000/live"),
            ("kpradio.hostingradio.ru:8000/russia.radiokp128.", "Радио «Комсомольская Правда» | КП Россия", "http://kpradio.hostingradio.ru:8000/russia.radiokp128.mp3"),
            ("rock.volna.top/RusRock", "Русский Рок", "http://rock.volna.top/RusRock"),
            ("retro70.hostingradio.ru:8025/retro70-128.", "Ретро FM 70e", "http://retro70.hostingradio.ru:8025/retro70-128.mp3"),
            ("chanson.hostingradio.ru:8041/chanson256.", "Радио Шансон - Radio Shanson", "http://chanson.hostingradio.ru:8041/chanson256.mp3"),
            ("listen1.myradio24.com/6262", "Спокойное радио", "https://listen1.myradio24.com/6262"),
            ("nashe.streamr.ru/nashe-128.", "Наше Радио", "http://nashe.streamr.ru/nashe-128.mp3"),
            ("retroserver.streamr.ru:8043/retro128", "Ретро ФМ", "http://retroserver.streamr.ru:8043/retro128"),
            ("nashe1.hostingradio.ru/ultra-192.", "Radio Ultra", "http://nashe1.hostingradio.ru/ultra-192.mp3"),
            ("rusradio.hostingradio.ru/rusradio96.p", "Русское Радио", "https://rusradio.hostingradio.ru/rusradio96.aacp"),
            
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
            ("176.9.30.66/cool64", "Cool Radio", "http://176.9.30.66/cool64"),
            ("sslstream.okradio.net/?type=http&nocache=8804", "OK radio", "https://sslstream.okradio.net/;?type=http&nocache=8804"),
            ("streaming.hitfm.rs:8000/hit", "Hit FM Radio Beograd", "http://streaming.hitfm.rs:8000/hit"),
            ("naxi48.streaming.rs:9180/listen.pls", "Naxi Radio", "http://naxi48.streaming.rs:9180/listen.pls"),
            ("stream.playradio.rs:8001/play..m3u", "Play", "http://stream.playradio.rs:8001/play.aac.m3u"),
            ("streaming.tdiradio.com:8000/tdiradio", "TDI Radio", "http://streaming.tdiradio.com:8000/tdiradio"),
            ("eu4.fastcast4u.com:5692/", "Moj radio", "http://eu4.fastcast4u.com:5692/"),
            ("nostalgie128.streaming.rs:9250/", "Radio Nostalgija", "http://nostalgie128.streaming.rs:9250/"),
            ("streaming.karolina.rs:8000/karolina", "Karolina", "http://streaming.karolina.rs:8000/karolina"),
            ("stream.radios.rs:9038/", "Radio S3 Južni", "https://stream.radios.rs:9038/;*.mp3"),
            ("streaming.tdiradio.com:8000/top40", "TDI Radio - Top 40", "http://streaming.tdiradio.com:8000/top40"),
            ("pink.exyuserver.com/stream.", "Pink radio", "http://pink.exyuserver.com/;stream.mp3"),
            ("antenaradio.org:4560/listen.pls", "Antena Radio Kruševac", "http://antenaradio.org:4560/listen.pls"),
            ("onair.superfm.rs/superfm.", "Super FM", "http://onair.superfm.rs/superfm.mp3"),
            ("streaming.tdiradio.com/radiolola.", "Radio Lola - Domaca", "https://streaming.tdiradio.com/radiolola.mp3"),
            ("mastermedia.shoutca.st/proxy/radioasfm?mp=/stream", "AS FM", "https://mastermedia.shoutca.st/proxy/radioasfm?mp=/stream"),
            ("radio.studiob.rs:8004/", "Radio Studio B", "http://radio.studiob.rs:8004/"),
            ("stream.radios.rs:9016/", "Radio S Narodni", "https://stream.radios.rs:9016/;*.mp3"),
            ("naxidigital-rock128.streaming.rs:8180/stream.nsv", "Naxi Radio - Rock", "http://naxidigital-rock128.streaming.rs:8180/;stream.nsv"),
            ("bumbum-stream.netlogic.rs:8000/listen.pls", "Bum Bum Radio", "http://bumbum-stream.netlogic.rs:8000/listen.pls"),
            ("rtsradio-live.morescreens.com/RTS_2_001/audio/chunklist.m3u8", "Radio Beograd 1", "https://rtsradio-live.morescreens.com/RTS_2_001/audio/chunklist.m3u8"),
            ("92.60.230.200:5040/", "Radio Belle Amie Niš", "http://92.60.230.200:5040/"),
            ("naxidigital-cafe128.streaming.rs:8020/stream.nsv", "Naxi Radio - Cafe", "http://naxidigital-cafe128.streaming.rs:8020/;stream.nsv"),
            ("ljubav.streaming.rs:9340/listen.pls", "Radio Ljubav", "http://ljubav.streaming.rs:9340/listen.pls"),
            ("breddstream.unrealhosting.hu:4120/", "Pannon Rádió", "http://breddstream.unrealhosting.hu:4120/;"),
            ("stream.playradio.rs:8443/play.", "Play Radio Serbia", "https://stream.playradio.rs:8443/play.mp3"),
            ("live.bucaradio.com:8080/listen.pls", "Radio Buca", "http://live.bucaradio.com:8080/listen.pls"),
            ("mastermedia.shoutca.st/proxy/prviradions?mp=/stream", "Prvi radio Novi Sad", "https://mastermedia.shoutca.st/proxy/prviradions?mp=/stream"),
            ("rfe05.akacast.akamaistream.net/7/510/437763/v1/ibb.akacast.akamaistream.net/rfe05?download=1", "Radio Slobodna Evropa", "http://rfe05.akacast.akamaistream.net/7/510/437763/v1/ibb.akacast.akamaistream.net/rfe05?download=1"),
            
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
            ("stream.radiovlna.sk/vlna-hi.", "Rádio Vlna", "http://stream.radiovlna.sk/vlna-hi.mp3"),
            ("stream.funradio.sk:8000/fun128.", "Fun Radio", "http://stream.funradio.sk:8000/fun128.mp3"),
            ("live.slovakradio.sk:8000/Slovensko_128.", "SRo1 Rádio Slovensko", "http://live.slovakradio.sk:8000/Slovensko_128.mp3"),
            ("live.slovakradio.sk:8000/Slovensko_256.", "SRo1 Rádio Slovensko", "http://live.slovakradio.sk:8000/Slovensko_256.mp3"),
            ("195.168.61.226:8000/96.", "Radio Expres", "http://195.168.61.226:8000/96.mp3"),
            ("icecast.stv.livebox.sk/fm_128.", "Radio FM", "https://icecast.stv.livebox.sk/fm_128.mp3"),
            ("stream.funradio.sk:8000/dance128.", "Fun Radio Dance", "http://stream.funradio.sk:8000/dance128.mp3"),
            ("109.71.67.102:8000/beta_80a90.", "Rádio Beta - Hity 80's a 90's", "http://109.71.67.102:8000/beta_80a90.mp3"),
            ("stream.funradio.sk:8000/80-90-128.", "Fun Radio 80&90", "http://stream.funradio.sk:8000/80-90-128.mp3"),
            ("listen.radioking.com/radio/276343/stream/321988", "Rádio Muzika", "https://listen.radioking.com/radio/276343/stream/321988"),
            ("dreamsiteradiocp5.com:8012/streaming.", "Rádio Maria Slovensko", "http://dreamsiteradiocp5.com:8012/streaming.mp3"),
            ("icecast.stv.livebox.sk/litera_128.", "SRo8 Rádio Litera", "http://icecast.stv.livebox.sk/litera_128.mp3"),
            ("audio.lumen.sk:8000/live128.", "Rádio Lumen", "http://audio.lumen.sk:8000/live128.mp3"),
            ("stream.expres.sk/128.", "Radio Expres SK", "https://stream.expres.sk/128.mp3"),
            ("109.71.67.102:8000/beta_cspop.", "Rádio Beta", "http://109.71.67.102:8000/beta_cspop.mp3"),
            ("stream.bauermedia.sk/europa2.", "Europa 2 ", "https://stream.bauermedia.sk/europa2.mp3"),
            ("stream.bauermedia.sk/melody-hi.", "Rádio Melody", "https://stream.bauermedia.sk/melody-hi.mp3"),
            ("live.slovakradio.sk:8000/FM_256.", "SRo4 Rádio FM", "http://live.slovakradio.sk:8000/FM_256.mp3"),
            ("icecast.stv.livebox.sk/regina-ke_128.", "SRo2 Rádio", "http://icecast.stv.livebox.sk/regina-ke_128.mp3"),
            ("icecast.stv.livebox.sk/devin_128.", "SRo3: Rádio Devín", "http://icecast.stv.livebox.sk/devin_128.mp3"),
            ("stream.rusyn.fm/rusyny.", "RusynFM", "http://stream.rusyn.fm/rusyny.mp3"),
            ("icecast.stv.livebox.sk/regina-bb_128.", "SRo2 Rádio Regina Stred", "http://icecast.stv.livebox.sk/regina-bb_128.mp3"),
            ("stream.ecce.sk:8000/radiokosice-128.", "Rádio Košice", "http://stream.ecce.sk:8000/radiokosice-128.mp3"),
            ("icecast.stv.livebox.sk/regina-ba_128.", "SRo2 Rádio Regina Západ", "http://icecast.stv.livebox.sk/regina-ba_128.mp3"),
            ("icecast.stv.livebox.sk/patria_128.", "Pátria Rádió", "https://icecast.stv.livebox.sk/patria_128.mp3"),
            ("radioserver.online:8804/stream/1", "Rádio Šírava", "http://radioserver.online:8804/;stream/1"),
            ("stream.frontinus.sk:8000/frontinus128.", "Rádio Frontinus", "http://stream.frontinus.sk:8000/frontinus128.mp3"),
            ("stream.zeno.fm/rw6ckefezs8uv", "Party Mix Radio", "http://stream.zeno.fm/rw6ckefezs8uv"),
            ("icecast.stv.livebox.sk/slovensko_128.", "Radio Slovensko", "https://icecast.stv.livebox.sk/slovensko_128.mp3"),
            ("159.69.219.5:8010/", "Slobodný vysielač", "http://159.69.219.5:8010/mp3"),
            
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
            ("edge.iono.fm/xice/jacarandafm_live_medium.", "Jacaranda FM", "https://edge.iono.fm/xice/jacarandafm_live_medium.aac"),
            ("capeant.antfarm.co.za:8000/Bosveld", "Bosveld Stereo", "http://capeant.antfarm.co.za:8000/Bosveld"),
            ("playerservices.streamtheworld.com/pls/FM947AAC.pls", "94.7 FM", "http://playerservices.streamtheworld.com/pls/FM947AAC.pls"),
            ("playerservices.streamtheworld.com/m3u/FM702.m3u", "702 Johannesburg FM", "http://playerservices.streamtheworld.com/m3u/FM702.m3u"),
            ("edge.iono.fm/xice/82_medium.", "Kaya FM", "https://edge.iono.fm/xice/82_medium.aac"),
            ("capeant.antfarm.co.za:8000/ptafm", "Pretoria FM", "http://capeant.antfarm.co.za:8000/ptafm"),
            ("bokradio.highquality.radiostream.co.za/", "Bokradio", "http://bokradio.highquality.radiostream.co.za/"),
            ("edge.iono.fm/xice/ecr_live_medium.", "ECR - East Coast Radio", "https://edge.iono.fm/xice/ecr_live_medium.aac"),
            ("listen.radioislam.co.za:8080/radioislam.", "Radio Islam International", "http://listen.radioislam.co.za:8080/radioislam.mp3"),
            ("zas3.ndx.co.za:8002/stream", "Lekker FM", "https://zas3.ndx.co.za:8002/stream"),
            ("stream.krypton.co.za:8040/stream/", "Radio 786", "http://stream.krypton.co.za:8040/stream/"),
            ("edge.iono.fm/xice/jacarandafm_live_high.", "Jakaranda FM", "https://edge.iono.fm/xice/jacarandafm_live_high.mp3"),
            ("playerservices.streamtheworld.com/m3u/CAPE_TALK.m3u", "Cape Talk", "http://playerservices.streamtheworld.com/m3u/CAPE_TALK.m3u"),
            ("edge.iono.fm/xice/49_medium.?p=embed", "Classic FM 1027", "http://edge.iono.fm/xice/49_medium.aac?p=embed"),
            ("stream.zeno.fm/xs6zeac1ts8uv", "Amapiano FM", "https://stream.zeno.fm/xs6zeac1ts8uv"),
            ("edge.iono.fm/xice/113_medium.", "Mix 93.8 FM", "https://edge.iono.fm/xice/113_medium.aac"),
            ("edge.iono.fm/xice/67_medium.", "Capricorn FM", "http://edge.iono.fm/xice/67_medium.aac"),
            ("25583.live.streamtheworld.com/KFM_SC", "Kfm", "http://25583.live.streamtheworld.com/KFM_SC"),
            ("servidor17.brlogic.com:7012/live", "JOY GOSPEL RADIO", "https://servidor17.brlogic.com:7012/live"),
            ("edge.iono.fm/xice/57_medium.", "HOT 91.9", "http://edge.iono.fm/xice/57_medium.mp3"),
            ("edge.iono.fm/xice/51_medium.", "Jozi FM", "https://edge.iono.fm/xice/51_medium.aac"),
            ("23543.live.streamtheworld.com/FM702AAC.", "702 Talk Radio", "https://23543.live.streamtheworld.com/FM702AAC.aac"),
            ("edge.iono.fm/xhls/82_high.m3u8", "KAYA FM 95.9", "http://edge.iono.fm/xhls/82_high.m3u8"),
            ("cast.fabrik.fm:8008/", "LM Radio South Africa", "http://cast.fabrik.fm:8008/"),
            ("edge.iono.fm/xice/57_high.", "Hot 102.7 FM", "https://edge.iono.fm/xice/57_high.aac"),
            ("edge.iono.fm/xice/65_medium.", "Power 98.7", "https://edge.iono.fm/xice/65_medium.aac"),
            ("streaming.coollective.nl:8443/UbuntuFM", "UbuntuFM", "https://streaming.coollective.nl:8443/UbuntuFM"),
            ("edge.iono.fm/xice/ofm_live_medium.", "OFM 94 & 97 FM", "http://edge.iono.fm/xice/ofm_live_medium.aac"),
            
            
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
            ("ibizaglobalradio.streaming-pro.com:8024/", "Ibiza Global Radio", "http://ibizaglobalradio.streaming-pro.com:8024/"),
            ("cadena100-streamers-.flumotion.com/cope/cadena100.", "Cadena 100", "http://cadena100-streamers-mp3.flumotion.com/cope/cadena100.mp3"),
            ("streaming5.elitecomunicacion.es:8082/live.", "Chocolate FM", "http://streaming5.elitecomunicacion.es:8082/live.mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/Los40.", "LOS 40 Principales España", "https://playerservices.streamtheworld.com/api/livestream-redirect/Los40.mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/CADENASER.", "Cadena SER España", "http://playerservices.streamtheworld.com/api/livestream-redirect/CADENASER.mp3"),
            ("c2.auracast.net:8048/stream", "1000 HITS 80s", "http://c2.auracast.net:8048/stream"),
            ("80sexitos.stream.laut.fm/80sexitos", "_80 EXITOS", "https://80sexitos.stream.laut.fm/80sexitos"),
            ("rockfm.cope.stream.flumotion.com/cope/rockfm-low..m3u", "Rock FM", "http://rockfm.cope.stream.flumotion.com/cope/rockfm-low.mp3.m3u"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/LOS40_URBAN.", "Los 40 Urban", "https://playerservices.streamtheworld.com/api/livestream-redirect/LOS40_URBAN.mp3"),
            ("livestreaming.esradio.fm/stream64.", "esRadio", "http://livestreaming.esradio.fm/stream64.mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/LOS40_DANCE_SC", "Los 40 Dance", "http://playerservices.streamtheworld.com/api/livestream-redirect/LOS40_DANCE_SC"),
            ("sonic.mediatelekom.net/9316/stream", "Radio Marca", "https://sonic.mediatelekom.net/9316/stream"),
            ("streaming5.elitecomunicacion.es:8082/live32.", "Chocolate FM", "http://streaming5.elitecomunicacion.es:8082/live32.aac"),
            ("flucast07-o-cloud.flumotion.com/cope/net2.", "Cope Directo 2", "https://flucast07-o-cloud.flumotion.com/cope/net2.mp3"),
            ("pureibizaradio.clubbingradios.com:9518/PureIbizaRadio", "Pure Ibiza Radio", "https://pureibizaradio.clubbingradios.com:9518/PureIbizaRadio"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/CADENADIAL.", "Cadena Dial", "http://playerservices.streamtheworld.com/api/livestream-redirect/CADENADIAL.mp3"),
            ("stream.cdm-chillout.com:8020/stream-AAC-Chill", "Costa Del Mar - Chillout", "http://stream.cdm-chillout.com:8020/stream-AAC-Chill"),
            ("radioweb.radiomarcabarcelona.com:9000/stream.m3u", "Radio Marca Barcelona", "http://radioweb.radiomarcabarcelona.com:9000/stream.m3u"),
            ("streams.radio.co/se1a320b47/listen", "Café del Mar", "https://streams.radio.co/se1a320b47/listen"),
            ("server7.20comunicacion.com:8040/", "Cadena SER Radio MADRID", "http://server7.20comunicacion.com:8040/"),
            ("megastar.cope.stream.flumotion.com/cope/megastar..m3u", "MegaStarFM", "http://megastar.cope.stream.flumotion.com/cope/megastar.mp3.m3u"),
            ("stream.mediasector.es/radio/8030/bikinifm.", "Bikini FM Marina Baja", "https://stream.mediasector.es/radio/8030/bikinifm.mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/RADIOMARCA_NACIONAL_SC", "Radio Marca Madrid", "https://playerservices.streamtheworld.com/api/livestream-redirect/RADIOMARCA_NACIONAL_SC"),
            ("s02.fjperezdj.com:8066/live", "Loca FM Deep Techno", "http://s02.fjperezdj.com:8066/live"),
            ("edge4.peta.live365.net/b05055_128", "Absolute Chillout", "http://edge4.peta.live365.net/b05055_128mp3"),
            ("playerservices.streamtheworld.com/api/livestream-redirect/LOS40_CLASSIC.", "LOS40 Classic", "https://playerservices.streamtheworld.com/api/livestream-redirect/LOS40_CLASSIC.mp3"),
            ("sevilla.copesedes.stream.flumotion.com/copesedes/sevilla..m3u", "Cope Sevilla", "http://sevilla.copesedes.stream.flumotion.com/copesedes/sevilla.mp3.m3u"),
            ("livestreaming3.esradio.fm/stream64.", "esRadio Madrid", "http://livestreaming3.esradio.fm/stream64.mp3"),
            ("rtvelivestream.akamaized.net/rtvesec/rne/rne_r1_main.m3u8?idasset=1712486", "RNE", "https://rtvelivestream.akamaized.net/rtvesec/rne/rne_r1_main.m3u8?idasset=1712486"),
            ("streams.radio.co/sdc9cfaf77/listen", "Ibiza Live Radio", "https://streams.radio.co/sdc9cfaf77/listen"),
            
            
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
            ("sverigesradio.se/topsy/direkt/132-hi-.pls", "Sveriges Radio - P1", "http://sverigesradio.se/topsy/direkt/132-hi-aac.pls"),
            ("tx-bauerse.sharp-stream.com/http_live.php?ua=WEB&i=mixmegapol_instream_se_", "Mix Megapol", "http://tx-bauerse.sharp-stream.com/http_live.php?ua=WEB&i=mixmegapol_instream_se_mp3"),
            ("tx-bauerse.sharp-stream.com/http_live.php?i=nrj_instreamtest_se_", "NRJ Sweden", "http://tx-bauerse.sharp-stream.com/http_live.php?i=nrj_instreamtest_se_mp3"),
            ("stream.piraterock.se:8101/webradio", "Pirate Rock", "http://stream.piraterock.se:8101/webradio"),
            ("sverigesradio.se/topsy/direkt/164-hi-.pls", "Sveriges Radio - P3", "http://sverigesradio.se/topsy/direkt/164-hi-aac.pls"),
            ("webradio.dbmedia.se/streams/crr96.pls", "Country Rocks Radio", "http://webradio.dbmedia.se/streams/crr96.pls"),
            ("tx-bauerse.sharp-stream.com/http_live.php?ua=WEB&i=rockklassiker_instream_se_", "106,7 Rockklassiker", "http://tx-bauerse.sharp-stream.com/http_live.php?ua=WEB&i=rockklassiker_instream_se_mp3"),
            ("webradio.dbmedia.se/streams/crrMP3.pls", "Country Rocks Radio", "http://webradio.dbmedia.se/streams/crrMP3.pls"),
            ("live-bauerse-fm.sharp-stream.com/retrofm_p?ua=WEB&aw_0_1st.playerid=SBS_RP_WEB&aw_0_1st.skey=1575715192&companionAds=true&listenerId=@@GUID@@", "Retro FM Skåne", "https://live-bauerse-fm.sharp-stream.com/retrofm_aacp?ua=WEB&aw_0_1st.playerid=SBS_RP_WEB&aw_0_1st.skey=1575715192&companionAds=true&listenerId=@@GUID@@"),
            ("tx.sharp-stream.com/http_live.php?i=svenskpop_se_", "Svensk Pop", "http://tx.sharp-stream.com/http_live.php?i=svenskpop_se_mp3"),
            ("stream.dbmedia.se/gkhbg96", "Guldkanalen Helsingborg", "http://stream.dbmedia.se/gkhbg96"),
            ("fm02-ice.stream.khz.se/fm02_", "Bandit Rock", "http://fm02-ice.stream.khz.se/fm02_mp3"),
            ("fm01-ice.stream.khz.se/fm01_", "Rix FM", "http://fm01-ice.stream.khz.se/fm01_mp3"),
            ("sverigesradio.se/topsy/direkt/4951-hi-.pls", "Sveriges Radio - P4 Plus", "http://sverigesradio.se/topsy/direkt/4951-hi-aac.pls"),
            ("mediaserv38.live-streams.nl:8107/stream", "Svensk Folkmusik - AkkA radio", "http://mediaserv38.live-streams.nl:8107/stream"),
            ("178.33.33.176:8060/listen.pls", "AORDreamer", "http://178.33.33.176:8060/listen.pls"),
            ("wr03-ice.stream.khz.se/wr03_", "Bandit Metal", "http://wr03-ice.stream.khz.se/wr03_mp3"),
            ("sverigesradio.se/topsy/direkt/2562-hi-.pls", "Sveriges Radio - P2", "http://sverigesradio.se/topsy/direkt/2562-hi-aac.pls"),
            ("fm03-ice.stream.khz.se/fm03_?", "Lugna Favoriter Stockholm", "http://fm03-ice.stream.khz.se/fm03_mp3?"),
            ("sverigesradio.se/topsy/direkt/212-hi-.m3u", "Sveriges Radio - P4 Göteborg", "https://sverigesradio.se/topsy/direkt/212-hi-mp3.m3u"),
            ("tx-bauerse.sharp-stream.com/http_live.php?i=mixmegapolgbg_instream_se_", "Mix Megapol GBG", "http://tx-bauerse.sharp-stream.com/http_live.php?i=mixmegapolgbg_instream_se_mp3"),
            ("sverigesradio.se/topsy/direkt/164-hi-.m3u", "Sveriges radio P3", "https://sverigesradio.se/topsy/direkt/164-hi-mp3.m3u"),
            ("scenesat.com/listen/normal/max.m3u", "SceneSat Radio (MP3)", "http://scenesat.com/listen/normal/max.m3u"),
            ("sverigesradio.se/topsy/direkt/132-hi-.m3u", "SVT P1", "http://sverigesradio.se/topsy/direkt/132-hi-mp3.m3u"),
            ("89.160.63.63/hitcity392kbps", "Hitcity", "http://89.160.63.63/hitcity392kbps"),
            ("stream.dbmedia.se/gk96", "Guldkanalen Malmö/Lund", "http://stream.dbmedia.se/gk96"),
            ("gold24.xnk.nu:8080/listen.pls", "Gold 102,4", "http://gold24.xnk.nu:8080/listen.pls"),
            ("62.101.46.15:8000/poporock", "Pop & Rock", "http://62.101.46.15:8000/poporock"),
            ("polushon.com/arch/playlist.pls", "Polushon", "http://polushon.com/arch/playlist.pls"),
            
            
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
            ("stream.srg-ssr.ch/m/rsj/_128", "Radio Swiss Jazz", "http://stream.srg-ssr.ch/m/rsj/mp3_128"),
            ("strm112.1.fm/deephouse_mobile_", "1.FM - Deep House Radio", "http://strm112.1.fm/deephouse_mobile_mp3"),
            ("strm112.1.fm/crock_mobile_", "1.FM - Classic Rock Replay Radio", "http://strm112.1.fm/crock_mobile_mp3"),
            ("strm112.1.fm/atr_mobile_", "1.FM - Amsterdam Trance Radio", "http://strm112.1.fm/atr_mobile_mp3"),
            ("strm112.1.fm/ccountry_mobile_", "1.FM - Classic Country Radio", "http://strm112.1.fm/ccountry_mobile_mp3"),
            ("strm112.1.fm/blues_mobile_", "1.FM - Blues Radio", "http://strm112.1.fm/blues_mobile_mp3"),
            ("strm112.1.fm/chilloutlounge_mobile_", "1.FM - Chillout Lounge Radio", "http://strm112.1.fm/chilloutlounge_mobile_mp3"),
            ("stream.srg-ssr.ch/m/rsc_de/_128", "Radio Swiss Classic German", "http://stream.srg-ssr.ch/m/rsc_de/mp3_128"),
            ("strm112.1.fm/rockclassics_mobile_", "1.FM - Rock Classics Radio", "http://strm112.1.fm/rockclassics_mobile_mp3"),
            ("strm112.1.fm/caferadio_mobile_", "1.FM - Cafe Radio", "http://strm112.1.fm/caferadio_mobile_mp3"),
            ("strm112.1.fm/bombaybeats_mobile_", "1.FM - Bombay Beats India Radio", "http://strm112.1.fm/bombaybeats_mobile_mp3"),
            ("stream.uzic.ch:9010/", "UZIC.CH ECHNO MINIMAL", "http://stream.uzic.ch:9010/"),
            ("stream.srg-ssr.ch/m/rsp/_128", "Radio Swiss Pop", "http://stream.srg-ssr.ch/m/rsp/mp3_128"),
            ("stream.srg-ssr.ch/m/drs3/_128", "SRF 3", "http://stream.srg-ssr.ch/m/drs3/mp3_128"),
            ("strm112.1.fm/highvoltage_mobile_", "1.FM - High Voltage Radio", "http://strm112.1.fm/highvoltage_mobile_mp3"),
            ("strm112.1.fm/deeptech_mobile_", "1.FM - Deep Techno & Deep House", "http://strm112.1.fm/deeptech_mobile_mp3"),
            ("strm112.1.fm/smoothjazz_mobile_", "1.FM - Bay Smooth Jazz Radio", "http://strm112.1.fm/smoothjazz_mobile_mp3"),
            ("strm112.1.fm/top40_mobile_", "1.FM - Absolute TOP 40 Radio", "http://strm112.1.fm/top40_mobile_mp3"),
            ("stream.srg-ssr.ch/m/drs4news/_128", "SRF 4 News", "http://stream.srg-ssr.ch/m/drs4news/mp3_128"),
            ("vibration.stream2net.eu:8220/stream/1", "Vibration Zen Relax", "http://vibration.stream2net.eu:8220/;stream/1"),
            ("spoonradio.ice.infomaniak.ch/spoonradio-hd", "Spoon Radio", "http://spoonradio.ice.infomaniak.ch/spoonradio-hd"),
            ("strm112.1.fm/x_mobile_", "1.FM - Alternative Rock", "http://strm112.1.fm/x_mobile_mp3"),
            ("broadcast.infomaniak.ch/energyzuerich-high.", "Energy Zürich", "http://broadcast.infomaniak.ch/energyzuerich-high.mp3"),
            ("strm112.1.fm/onelive_mobile_", "1.FM - America's Best Ballads Radio", "http://strm112.1.fm/onelive_mobile_mp3"),
            ("strm112.1.fm/baroque_mobile_", "1.FM - Otto's Baroque Music Radio", "http://strm112.1.fm/baroque_mobile_mp3"),
            ("strm112.1.fm/gorillafm_mobile_", "1.FM - Gorilla FM Radio", "http://strm112.1.fm/gorillafm_mobile_mp3"),
            ("strm112.1.fm/reggae_mobile_", "1.FM - ReggaeTrade Radio", "http://strm112.1.fm/reggae_mobile_mp3"),
            ("strm112.1.fm/psytrance_mobile_", "1.FM - BOM Psytrance Radio", "http://strm112.1.fm/psytrance_mobile_mp3"),
            ("strm112.1.fm/country_mobile_", "1.FM - Country One Radio", "http://strm112.1.fm/country_mobile_mp3"),
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
            ("eu6.fastcast4u.com:5306/", "Clouds FM", "http://eu6.fastcast4u.com:5306/;"),
            ("dreamsiteradiocp2.com:8034/stream", "RADIO MARIA TANZANIA", "http://dreamsiteradiocp2.com:8034/stream"),
            ("eatv.radioca.st/stream", "East Africa Radio FM", "https://eatv.radioca.st/stream"),
            ("radioonetanzania.radioca.st/stream", "Radio One Stereo", "https://radioonetanzania.radioca.st/stream"),
            ("streaming.radionomy.com/JamendoLounge", "Wasafi Fm", "http://streaming.radionomy.com/JamendoLounge"),
            ("uk4-vn.mixstream.net:8052/listen.", "Radio Kwizera", "http://uk4-vn.mixstream.net:8052/;listen.mp3"),
            ("s2.citrus3.com:8050/stream", "Radio Uhai", "https://s2.citrus3.com:8050/stream"),
            ("capitalradio.radioca.st/stream", "Capital Radio", "https://capitalradio.radioca.st/stream"),
            ("dreamsiteradiocp5.com:8004/stream.", "Radio Mbiu", "http://dreamsiteradiocp5.com:8004/stream.mp3"),
            ("stream.zeno.fm/7ebq5q3tcv8uv", "Kipiti Radio", "http://stream.zeno.fm/7ebq5q3tcv8uv"),
            ("stream.zeno.fm/d3as2fmadnruv", "street One radio", "http://stream.zeno.fm/d3as2fmadnruv"),
            ("stream.zeno.fm/eequgfw72hhvv", "Heaven FM Radio", "http://stream.zeno.fm/eequgfw72hhvv"),
            ("138.68.138.119:8080/low/5a8993709ea19/index.m3u8", "IBN TV", "http://138.68.138.119:8080/low/5a8993709ea19/index.m3u8"),
            ("stream.zeno.fm/41e3gsdgmdouv", "Radio Ngamia", "http://stream.zeno.fm/41e3gsdgmdouv"),
            ("radiotadio.co.tz/dodoma-fm-stream", "Dodoma FM", "https://radiotadio.co.tz/dodoma-fm-stream"),
            ("stream.rcast.net/69241/", "Magic FM Dar es Salaam", "https://stream.rcast.net/69241/;"),
            ("radiotadio.co.tz/nuru-fm-stream", "Nuru FM", "https://radiotadio.co.tz/nuru-fm-stream"),
            ("stream.zeno.fm/ex6ng25chfhvv", "Daniel Edward ", "http://stream.zeno.fm/ex6ng25chfhvv"),
            ("stream.zeno.fm/mtrcigb9yhitv", "Deliverance Radio ", "https://stream.zeno.fm/mtrcigb9yhitv"),
            ("stream.zeno.fm/fygodpmrgcquv", "DFM Radio ", "https://stream.zeno.fm/fygodpmrgcquv"),
            ("stream.zeno.fm/pjyrau0imf3uv", "sunsee fm", "https://stream.zeno.fm/pjyrau0imf3uv"),
            ("stream.zeno.fm/dsfhivkawjiuv", "ImbaNasi", "https://stream.zeno.fm/dsfhivkawjiuv"),
            
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
            ("46.20.3.201/", "Kral Pop", "http://46.20.3.201/"),
            ("46.20.3.204/", "Kral FM", "http://46.20.3.204/"),
            ("yayin.arabeskfm.biz:8042/", "Arabesk FM", "http://yayin.arabeskfm.biz:8042/"),
            ("provisioning.streamtheworld.com/pls/VIRGIN_RADIO.pls", "Virgin Radio Türkiye", "http://provisioning.streamtheworld.com/pls/VIRGIN_RADIO.pls"),
            ("46.20.7.126/stream.", "Best Fm", "http://46.20.7.126/;stream.mp3"),
            ("37.247.98.8/listen.pls?sid=22", "Türkülerle Türkiye", "http://37.247.98.8/listen.pls?sid=22"),
            ("live.radyositesihazir.com:10997/", "DAMAR TURK FM", "https://live.radyositesihazir.com:10997/"),
            ("live.radyositesihazir.com/8078/stream", "Radyo Şiran", "https://live.radyositesihazir.com/8078/stream"),
            ("46.20.3.250/stream", "Radyo 7", "http://46.20.3.250/;stream"),
            ("server.gitassi.com:4545/stream", "RADYO 45 LIK", "http://server.gitassi.com:4545/stream"),
            ("provisioning.streamtheworld.com/pls/METRO_FMAAC.pls", "Metro FM", "http://provisioning.streamtheworld.com/pls/METRO_FMAAC.pls"),
            ("46.20.3.207/listen.pls", "NTV Radyo", "http://46.20.3.207/listen.pls"),
            ("radyo.yayin.com.tr/tunein/radiotrc.asx", "Radio 5 Turkey", "https://radyo.yayin.com.tr/tunein/radiotrc.asx"),
            ("listen.powerapp.com.tr/powerpop/128/chunks.m3u8", "Power POP", "https://listen.powerapp.com.tr/powerpop/128/chunks.m3u8"),
            ("turkmedya.radyotvonline.com/turkmedya/alemfm.stream/playlist.m3u8", "Alem FM", "http://turkmedya.radyotvonline.com/turkmedya/alemfm.stream/playlist.m3u8"),
            ("46.20.7.125/", "Best FM", "http://46.20.7.125/"),
            ("37.247.98.8/listen.pls?sid=30", "Ankara Havalari", "http://37.247.98.8/listen.pls?sid=30"),
            ("37.247.98.8/listen.pls?sid=25", "ALTIN SARKILAR", "http://37.247.98.8/listen.pls?sid=25"),
            ("live.radyositesihazir.com/8032/stream", "KRAL TÜRK FM", "https://live.radyositesihazir.com/8032/stream"),
            ("46.20.7.116/", "Baba Radyo", "http://46.20.7.116/"),
            ("radyodejavu.canliyayinda.com:8054/", "Radyo Dejavu", "http://radyodejavu.canliyayinda.com:8054/"),
            ("stream.34bit.net/ar64.", "Açık Radyo", "http://stream.34bit.net/ar64.mp3"),
            ("95.0.173.195:9000/turku", "Radyo Vatan Türkü", "http://95.0.173.195:9000/turku"),
            ("provisioning.streamtheworld.com/pls/SUPER_FMAAC.pls", "Süper FM", "http://provisioning.streamtheworld.com/pls/SUPER_FMAAC.pls"),
            ("trkvz-radyolar.ercdn.net/ahaberradyo/playlist.m3u8", "a HABER", "https://trkvz-radyolar.ercdn.net/ahaberradyo/playlist.m3u8"),
            ("channels.dinamo.fm/sleep-", "dinamo.fm sleep", "http://channels.dinamo.fm/sleep-mp3"),
            ("live.radyofenomen.com/fenomen/128/icecast.audio", "Radyo Fenomen", "https://live.radyofenomen.com/fenomen/128/icecast.audio"),
            ("yayin.radyoseymen.com.tr:1070/stream", "Radyo Seymen", "https://yayin.radyoseymen.com.tr:1070/stream"),
            ("live.radyositesihazir.com:10997/stream?type=http&nocache=99881", "DamarTurk FM", "https://live.radyositesihazir.com:10997/stream?type=http&nocache=99881"),
            ("radyo.turkuradyo.net:4591/listen.pls", "Turku Radyo", "http://radyo.turkuradyo.net:4591/listen.pls"),
            
            
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
            ("stream.live.vc.bbcmedia.co.uk/bbc_world_service", "BBC World Service", "http://stream.live.vc.bbcmedia.co.uk/bbc_world_service"),
            ("samcloud.spacial.com/api/listen?sid=111415&rid=194939&f=,any&br=128000,any&m=sc", "#1980s Zoom", "https://samcloud.spacial.com/api/listen?sid=111415&rid=194939&f=mp3,any&br=128000,any&m=sc"),
            ("radio.talksport.com/stream?aisGetOriginalStream=true", "talkSPORT", "http://radio.talksport.com/stream?aisGetOriginalStream=true"),
            ("78.129.202.200:8040/", "Radio Caroline", "http://78.129.202.200:8040/;"),
            ("media-ice.musicradio.com/CapitalMP3", "Capital FM London", "http://media-ice.musicradio.com/CapitalMP3"),
            ("ice55.securenetsystems.net/DASH7", "80's on Dash", "http://ice55.securenetsystems.net/DASH7"),
            ("ice-sov.musicradio.com/HeartLondonMP3", "Heart London 106.2 FM", "http://ice-sov.musicradio.com/HeartLondonMP3"),
            ("media-ssl.musicradio.com/Heart80sMP3", "Heart 80s", "https://media-ssl.musicradio.com/Heart80sMP3"),
            ("media-the.musicradio.com/SmoothEastMids", "Smooth Radio", "http://media-the.musicradio.com/SmoothEastMids"),
            ("radio.virginradio.co.uk/stream", "Virgin Radio UK", "http://radio.virginradio.co.uk/stream"),
            ("svr1.msmn.co:8136/", "NME 1 - Classic & New Indie", "http://svr1.msmn.co:8136/"),
            ("media-ssl.musicradio.com/Heart70sMP3", "Heart 70s", "https://media-ssl.musicradio.com/Heart70sMP3"),
            ("radio.talkradio.co.uk/stream", "talkRADIO", "http://radio.talkradio.co.uk/stream"),
            ("46.28.49.164:7504/stream", "Retro Soul Radio", "http://46.28.49.164:7504/stream"),
            ("media-ssl.musicradio.com/GoldMP3", "Gold", "https://media-ssl.musicradio.com/GoldMP3"),
            ("media-ice.musicradio.com/ClassicFMMP3", "Classic FM", "http://media-ice.musicradio.com/ClassicFMMP3"),
            ("radio.canstream.co.uk:8075/live.", "Jazz London Radio", "http://radio.canstream.co.uk:8075/live.mp3"),
            ("media-ssl.musicradio.com/ChillMP3", "Smooth Chill", "https://media-ssl.musicradio.com/ChillMP3"),
            ("msmn.co:8118/stream", "NME 2 - New & Upfront Indie Alt", "http://msmn.co:8118/;stream"),
            ("media-ssl.musicradio.com/Heart90sMP3", "Heart 90s", "https://media-ssl.musicradio.com/Heart90sMP3"),
            ("media-sov.musicradio.com/LBCLondon", "LBC London (London stream) AAC", "http://media-sov.musicradio.com/LBCLondon"),
            ("stream.kanefm.com:1037/stream", "Kane FM", "http://stream.kanefm.com:1037/;stream"),
            ("media-ssl.musicradio.com/HeartDanceMP3", "Heart Dance", "https://media-ssl.musicradio.com/HeartDanceMP3"),
            ("timesradio.wireless.radio/stream", "Times Radio UK", "http://timesradio.wireless.radio/stream"),
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
            ("stream-uk1.radioparadise.com/-320", "Radio Paradise", "http://stream-uk1.radioparadise.com/aac-320"),
            ("icecast.walmradio.com:8443/classic", "Classic Vinyl HD", "https://icecast.walmradio.com:8443/classic"),
            ("icecast.walmradio.com:8443/jazz", "Adroit Jazz Underground", "https://icecast.walmradio.com:8443/jazz"),
            ("icecast.walmradio.com:8443/christmas", "Christmas Vinyl", "https://icecast.walmradio.com:8443/christmas"),
            ("icecast.walmradio.com:8443/walm", "WALM HD", "https://icecast.walmradio.com:8443/walm"),
            ("icecast.walmradio.com:8443/walm2", "WALM 2 HD", "https://icecast.walmradio.com:8443/walm2"),
            ("icecast.walmradio.com:8443/otr", "WALM - Old Time Radio", "https://icecast.walmradio.com:8443/otr"),
            ("198.15.94.34:8006/stream", "Deep House Lounge", "http://198.15.94.34:8006/stream"),
            ("101smoothjazz.com/101-smoothjazz.m3u", "101 SMOOTH JAZZ", "http://www.101smoothjazz.com/101-smoothjazz.m3u"),
            ("radiopanther.radiolebowski.com/play", "CLASSIC HITS RADIO 70 80", "https://radiopanther.radiolebowski.com/play"),
            ("ice10.outlaw.fm/KIEV2", "Outlaw Country Radio", "http://ice10.outlaw.fm/KIEV2"),
            ("playerservices.streamtheworld.com/pls/977_80.pls", "977 80s", "http://playerservices.streamtheworld.com/pls/977_80.pls"),
            ("playerservices.streamtheworld.com/pls/977_MIX.pls", ".977 The Mix", "http://playerservices.streamtheworld.com/pls/977_MIX.pls"),
            ("playerservices.streamtheworld.com/pls/977_HITS.pls", ".977 Hitz", "http://playerservices.streamtheworld.com/pls/977_HITS.pls"),
            ("playerservices.streamtheworld.com/pls/977_COUNTRY.pls", ".977 Country", "http://playerservices.streamtheworld.com/pls/977_COUNTRY.pls"),
            ("listen.181fm.com/181-oldschool_128k.", "181.FM - Old School HipHop/RnB", "http://listen.181fm.com/181-oldschool_128k.mp3"),
            ("relax.stream.publicradio.org/relax.", "Your Classical - Relax", "http://relax.stream.publicradio.org/relax.mp3"),
            ("voa-28.akacast.akamaistream.net/7/54/322040/v1/ibb.akacast.akamaistream.net/voa-28", "VOA Voice of America", "http://voa-28.akacast.akamaistream.net/7/54/322040/v1/ibb.akacast.akamaistream.net/voa-28"),
            ("radio.stereoscenic.com/asp-h", "Ambient Sleeping Pill", "http://radio.stereoscenic.com/asp-h"),
            ("lin3.ash.fast-serv.com:6026/stream_96", "Rockabilly-radio.net", "http://lin3.ash.fast-serv.com:6026/stream_96"),
            ("ice3.somafm.com/groovesalad-128-", "SomaFM Groove Salad", "http://ice3.somafm.com/groovesalad-128-mp3"),
            ("stream2.friskyradio.com/frisky__hi", "Frisky", "http://stream2.friskyradio.com/frisky_mp3_hi"),
            ("ice.somafm.com/secretagent", "SomaFM Secret Agent", "http://ice.somafm.com/secretagent"),
            ("bigrradio.cdnstream1.com/5186_128", "Big R Radio - 80s Metal FM", "http://bigrradio.cdnstream1.com/5186_128"),
            ("stream-.infowars.com/", "Infowars", "http://stream-mp3.infowars.com/"),
            ("somafm.com/u80s.pls", "SomaFM Underground 80s", "http://somafm.com/u80s.pls"),
            ("bassdrive.com/bassdrive.m3u", "Bassdrive", "http://bassdrive.com/bassdrive.m3u"),
            ("listen.cdnstream.com/hrhradio/1521_128.m3u", "Hard Rock Heaven", "http://listen.cdnstream.com/hrhradio/1521_128.m3u"),
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
            ("edge.iono.fm/xice/162_medium.", "Capitalk 100.4FM Harare", "https://edge.iono.fm/xice/162_medium.aac"),
            ("edge.iono.fm/xice/159_medium.", "Star FM 89.7", "https://edge.iono.fm/xice/159_medium.aac"),
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
    
    @StateObject private var viewModel = RadioStationViewModel()
    static func addAllDefaults(to viewModel: RadioStationViewModel) {
        /*
        addDefaultStationsForAlbania(to: viewModel)
    
        addDefaultStationsForRomania(to: viewModel)
        addDefaultStationsForAlbania(to: viewModel)
        addDefaultStationsForRomania(to: viewModel)
        addDefaultStationsForPanama(to: viewModel)
        addDefaultStationsForAngola(to: viewModel)
        addDefaultStationsForArgentina(to: viewModel)
        addDefaultStationsForAustralia(to: viewModel)
        addDefaultStationsForBangladesh(to: viewModel)
        addDefaultStationsForBolivia(to: viewModel)
        addDefaultStationsForBrazil(to: viewModel)
        addDefaultStationsForChina(to: viewModel)
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
        addDefaultStationsForPanama(to: viewModel)
        addDefaultStationsForPeru(to: viewModel)
        addDefaultStationsForPoland(to: viewModel)
        addDefaultStationsForPortugal(to: viewModel)
        addDefaultStationsForRomania(to: viewModel)
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

