//
//  CDStation.swift
//  StreamRadios
//
//  Created by Kley Sulo on 7/9/24.
//

import CoreData

@objc(CDStation)
public class CDStation: NSManagedObject {
    @NSManaged public var id: String?
    @NSManaged public var name: String?
    @NSManaged public var url: String?
    @NSManaged public var iconData: String?
    @NSManaged public var country: String?
    @NSManaged public var isFavorite: Bool
}

