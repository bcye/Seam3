//    CKRecord+NSManagedObject.swift
//
//    The MIT License (MIT)
//
//    Copyright (c) 2016 Paul Wilkinson ( https://github.com/paulw11 )
//
//    Based on work by Nofel Mahmood
//
//    Portions copyright (c) 2015 Nofel Mahmood ( https://twitter.com/NofelMahmood )
//
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, and to permit persons to whom the Software is
//    furnished to do so, subject to the following conditions:
//
//    The above copyright notice and this permission notice shall be included in all
//    copies or substantial portions of the Software.
//
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//    SOFTWARE.


import Foundation
import CoreData
import CloudKit
import os.log

extension CKRecord {
    
    func allAttributeKeys(usingAttributesByNameFromEntity attributesByName: [String:NSAttributeDescription]) -> [String] {
        return self.allKeys().filter({ (key) -> Bool in
            return attributesByName[key] != nil
        })
    }
    
    func allReferencesKeys(usingRelationshipsByNameFromEntity relationshipsByName: [String:NSRelationshipDescription]) -> [String] {
        return self.allKeys().filter({ (key) -> Bool in
            return relationshipsByName[key] != nil
        })
    }
    
    class func recordWithEncodedFields(_ encodedFields: Data) -> CKRecord {
        let coder = NSKeyedUnarchiver(forReadingWith: encodedFields)
        let record: CKRecord = CKRecord(coder: coder)!
        coder.finishDecoding()
        return record
    }
    
    func encodedSystemFields() -> Data {
        let data = NSMutableData()
        let coder = NSKeyedArchiver(forWritingWith: data)
        self.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return data as Data
    }
    
    fileprivate func allAttributeValuesAsManagedObjectAttributeValues(usingContext context: NSManagedObjectContext) -> [String:AnyObject]? {
        if let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[self.recordType] {
            return self.dictionaryWithValues(forKeys: self.allAttributeKeys(usingAttributesByNameFromEntity: entity.attributesByName)) as [String : AnyObject]?
        } else {
            return nil
        }
    }
    
    fileprivate func allCKReferencesAsManagedObjects(usingContext context: NSManagedObjectContext, forManagedObject managedObject: NSManagedObject) throws -> [String:AnyObject]? {
        if let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[self.recordType] {
            let referencesValuesDictionary = self.dictionaryWithValues(forKeys: self.allReferencesKeys(usingRelationshipsByNameFromEntity: entity.relationshipsByName))
            var managedObjectsDictionary: Dictionary<String,AnyObject> = Dictionary<String,AnyObject>()
            for (key,value) in referencesValuesDictionary {
                if let relationshipDescription = entity.relationshipsByName[key] {
                    if let destinationEntity = relationshipDescription.destinationEntity {
                        if let name = destinationEntity.name  {
                            let recordIDString = (value as! CKRecord.Reference).recordID.recordName
                            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                            fetchRequest.predicate = NSPredicate(format: "%K == %@", SMStore.SMLocalStoreRecordIDAttributeName,recordIDString)
                            fetchRequest.fetchLimit = 1
                            let results = try context.fetch(fetchRequest)
                            if !results.isEmpty {
                                let relationshipManagedObject: NSManagedObject = results.last as! NSManagedObject
                                managedObjectsDictionary[key] = relationshipManagedObject
                            } else {
                                SMStore.logger?.info("WARNING Missing NON-OPTIONAL related object for \(entity.name ?? "nil").\(key)' (missing '\(name)' (\(recordIDString)) )")
                                context.refresh(managedObject, mergeChanges: false)
                                throw SMStoreError.missingRelatedObject
                            }
                        }
                    }
                }
            }
            return managedObjectsDictionary
        }
        return nil
    }
    
    public func createOrUpdateManagedObjectFromRecord(usingContext context: NSManagedObjectContext) throws -> NSManagedObject? {
        
        if let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[self.recordType] {
            if let entityName = entity.name  {
                var managedObject: NSManagedObject?
                let recordIDString = self.recordID.recordName
                let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                fetchRequest.fetchLimit = 1
                fetchRequest.predicate = NSPredicate(format: "%K == %@", SMStore.SMLocalStoreRecordIDAttributeName, recordIDString)
                let results = try context.fetch(fetchRequest)
                if !results.isEmpty {
                    managedObject = results.last as? NSManagedObject
                    SMStore.logger?.debug("OK will update existing object from CKRecord \(entityName), recordID=\(recordIDString)")
                }
                
                if managedObject == nil {
                    managedObject = NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
                    managedObject!.setValue(recordIDString, forKey: SMStore.SMLocalStoreRecordIDAttributeName)
                    SMStore.logger?.debug("OK will insert new object from CKRecord \(entityName), recordID=\(recordIDString)")
                }
                
                try self.setValuesOn(managedObject!, inContext:context)
                return managedObject
            }
        }
        throw SMStoreError.backingStoreUpdateError
    }
    
    
    
    private func setValuesOn(_ managedObject: NSManagedObject, inContext context: NSManagedObjectContext ) throws {
        
        let attributes = managedObject.entity.attributesByName
        var transformableAttributeKeys = Set<String>()
        for (key, attributeDescription) in attributes {
            if attributeDescription.attributeType == NSAttributeType.transformableAttributeType {
                transformableAttributeKeys.insert(key)
            }
        }
        managedObject.setValue(self.encodedSystemFields(), forKey: SMStore.SMLocalStoreRecordEncodedValuesAttributeName)
        if var valuesDictionary = self.allAttributeValuesAsManagedObjectAttributeValues(usingContext: context)  {
            valuesDictionary = self.replaceAssets(in:valuesDictionary)
            valuesDictionary = self.transformAttributes(in: valuesDictionary, keys: transformableAttributeKeys)
            managedObject.setValuesForKeys(valuesDictionary)
        }
        let referencesValuesDictionary = try self.allCKReferencesAsManagedObjects(usingContext: context, forManagedObject: managedObject)
        if referencesValuesDictionary != nil {
            for (key,value) in referencesValuesDictionary! {
                managedObject.setValue(value, forKey: key)
            }
        }
    }
    
    private func transformAttributes(in dictionary: [String:AnyObject], keys: Set<String>) -> [String:AnyObject] {
        
        var returnDict = [String:AnyObject]()
        for (key,value) in dictionary {
            if keys.contains(key) {
                if let data = dictionary[key] as? Data {
                    let unarchived = NSKeyedUnarchiver.unarchiveObject(with: data) as AnyObject
                    returnDict[key] = unarchived
                }
            } else {
                returnDict[key] = value
            }
        }
        return returnDict
    }
    
    private func replaceAssets(in dictionary: [String:AnyObject]) -> [String:AnyObject] {
        var returnDict = [String:AnyObject]()
        for (key,value) in dictionary {
            if let val = value as? CKAsset {
                if let assetData = NSData(contentsOfFile: val.fileURL.path) {
                    returnDict[key] = assetData
                }
            } else {
                returnDict[key] = value
            }
        }
        
        return returnDict
        
    }
}
